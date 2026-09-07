import AgenticInterfaces
import AgenticRuntime
import DSL
import ErrorsDSL
import Foundation
import Terminal

package struct AgenticConversationRunProjection {
    package var run: AgenticHostConsoleRunPresentation
    package var documents: [AgenticHostConsoleDocumentPresentation]
    package var interruptions: [AgenticHostConsoleInterruptionPresentation]

    package static func project(
        _ state: AgentRunStateSnapshot,
        title: String
    ) -> Self {
        guard !state.toolUses.isEmpty else {
            return .init(
                run: .init(
                    id: state.sessionID,
                    title: title,
                    summary: state.failure?.message,
                    state: runState(
                        for: state.phase
                    ),
                    steps: []
                ),
                documents: [],
                interruptions: approvalInterruptions(
                    sessionID: state.sessionID,
                    pendingApproval: state.pendingApproval
                )
            )
        }

        var projection = project(
            AgentRunResult(
                sessionID: state.sessionID,
                response: state.lastResponse,
                suspension: state.suspension,
                pendingApproval: state.pendingApproval,
                failure: state.failure,
                state: state.state,
                events: state.events,
                toolUses: state.toolUses,
                costRecord: state.costRecord
            ),
            title: title
        )

        projection.run.state = runState(
            for: state.phase
        )

        if projection.run.summary == nil {
            projection.run.summary = state.failure?.message
        }

        return projection
    }

    package static func project(
        _ result: AgentRunResult,
        title: String
    ) -> Self {
        let eventsByCallID = Dictionary(
            grouping: result.events.compactMap { event -> AgentRunEvent? in
                event.toolCallID == nil
                    ? nil
                    : event
            },
            by: { event in
                event.toolCallID!
            }
        )

        var documents: [AgenticHostConsoleDocumentPresentation] = []
        var steps: [AgenticHostConsoleStepPresentation]

        if result.toolUses.isEmpty {
            steps = legacySteps(
                for: result,
                eventsByCallID: eventsByCallID,
                documents: &documents
            )
        } else {
            steps = result.toolUses.map { record in
                let callID = record.toolCall.id
                let events = eventsByCallID[callID] ?? []
                let state = stepState(for: record)
                let projection = record.result?.processing?.projection

                var fields: [AgenticHostConsoleField] = [
                    .init("outcome", state.rawValue),
                    .init("disposition", record.disposition.rawValue),
                ]

                if let preflight = record.preflight {
                    fields.append(
                        .init(
                            "risk",
                            preflight.risk.rawValue
                        )
                    )
                }

                if let projection {
                    fields.append(
                        .init(
                            "result",
                            projection.status
                        )
                    )
                }

                if let iteration = events.map(\.iteration).max() {
                    fields.append(
                        .init(
                            "iteration",
                            String(iteration)
                        )
                    )
                }

                documents.append(
                    .init(
                        id: "\(result.sessionID)-\(callID)-details",
                        runID: result.sessionID,
                        stepID: callID,
                        kind: .details,
                        title: "Tool use",
                        body: detailsBody(
                            for: record,
                            events: events
                        ),
                        structuredBody: detailsContent(
                            for: record,
                            events: events
                        )
                    )
                )

                if let diffPreview = record.preflight?.diffPreview,
                   !diffPreview.isEmpty
                {
                    let renderedDiff: String

                    if let layout = diffPreview.layout {
                        renderedDiff = TerminalDifferenceRenderer.render(
                            layout,
                            options: .init(
                                base: .init(
                                    showHeader: true,
                                    showUnchangedLines: false,
                                    contextLineCount: diffPreview.contextLineCount
                                )
                            )
                        )
                    } else {
                        renderedDiff = diffPreview.text
                    }

                    documents.append(
                        .init(
                            id: "\(result.sessionID)-\(callID)-diff",
                            runID: result.sessionID,
                            stepID: callID,
                            kind: .diff,
                            title: diffPreview.title ?? "Diff",
                            body: renderedDiff
                        )
                    )
                }

                if let toolResult = record.result {
                    let observations =
                        toolResult.processing?.observations
                            ?? []

                    let stdout = observations
                        .filter {
                            $0.kind == .standard_output
                        }
                        .map(\.content)
                        .joined()

                    documents.append(
                        .init(
                            id: "\(result.sessionID)-\(callID)-stdout",
                            runID: result.sessionID,
                            stepID: callID,
                            kind: .stdout,
                            title: "stdout",
                            body: stdout.isEmpty
                                ? "stdout is empty."
                                : stdout
                        )
                    )

                    let stderr = observations
                        .filter {
                            $0.kind == .standard_error
                        }
                        .map(\.content)
                        .joined()

                    documents.append(
                        .init(
                            id: "\(result.sessionID)-\(callID)-stderr",
                            runID: result.sessionID,
                            stepID: callID,
                            kind: .stderr,
                            title: "stderr",
                            body: stderr.isEmpty
                                ? "stderr is empty."
                                : stderr
                        )
                    )
                }

                return .init(
                    id: callID,
                    title: record.toolCall.name,
                    detail:
                        projection?.summary
                            ?? record.preflight?.summary
                            ?? events.last?.summary,
                    state: state,
                    fields: fields
                )
            }
        }

        if let failure = result.failure {
            let stepID = "\(result.sessionID)-failure"

            steps.append(
                .init(
                    id: stepID,
                    title: "run failure",
                    detail: failure.message,
                    state: .failed,
                    fields: [
                        .init(
                            "outcome",
                            AgenticHostConsoleStepState
                                .failed
                                .rawValue
                        ),
                        .init(
                            "kind",
                            failure.kind.rawValue
                        ),
                        .init(
                            "iteration",
                            String(
                                result.state.iteration
                            )
                        ),
                    ]
                )
            )
            documents.append(
                .init(
                    id: "\(stepID)-details",
                    runID: result.sessionID,
                    stepID: stepID,
                    kind: .details,
                    title: "Failure details",
                    body: [
                        "kind     \(failure.kind.rawValue)",
                        "message  \(failure.message)",
                    ].joined(separator: "\n"),
                    structuredBody:
                        failure.report?.structuredContent
                )
            )
        }

        return .init(
            run: .init(
                id: result.sessionID,
                title: title,
                summary:
                    result.failure?.message
                        ?? steps.last?.detail,
                state: runState(
                    for: result
                ),
                steps: steps
            ),
            documents: documents,
            interruptions: approvalInterruptions(
                sessionID: result.sessionID,
                pendingApproval: result.pendingApproval
            )
        )
    }

    private static func approvalInterruptions(
        sessionID: String,
        pendingApproval: PendingApproval?
    ) -> [AgenticHostConsoleInterruptionPresentation] {
        guard let pendingApproval else {
            return []
        }

        let stepID = pendingApproval.toolCall.id

        return [
            .init(
                id: "\(sessionID)-\(stepID)-approval",
                runID: sessionID,
                stepID: stepID,
                kind: .approval,
                title: "Approval required",
                summary: pendingApproval.preflight.summary,
                actions: [
                    .approve,
                    .deny,
                    .skip,
                ]
            ),
        ]
    }

    private static func legacySteps(
        for result: AgentRunResult,
        eventsByCallID: [String: [AgentRunEvent]],
        documents: inout [AgenticHostConsoleDocumentPresentation]
    ) -> [AgenticHostConsoleStepPresentation] {
        var order: [String] = []

        for event in result.events {
            guard let callID = event.toolCallID else {
                continue
            }

            if !order.contains(callID) {
                order.append(callID)
            }
        }

        return order.compactMap { callID in
            guard let events = eventsByCallID[callID] else {
                return nil
            }

            let title =
                events.compactMap(\.toolName).last
                    ?? callID
            let state = stepState(
                for: events
            )
            let detail = events.last?.summary
            let body = events.map {
                "[iteration \($0.iteration)] \($0.kind.rawValue): \($0.summary)"
            }.joined(separator: "\n")

            documents.append(
                .init(
                    id: "\(result.sessionID)-\(callID)-details",
                    runID: result.sessionID,
                    stepID: callID,
                    kind: .details,
                    body: body
                )
            )

            return .init(
                id: callID,
                title: title,
                detail: detail,
                state: state,
                fields: [
                    .init(
                        "outcome",
                        state.rawValue
                    ),
                    .init(
                        "events",
                        String(
                            events.count
                        )
                    ),
                    .init(
                        "iteration",
                        String(
                            events
                                .map(\.iteration)
                                .max()
                                ?? 0
                        )
                    ),
                ]
            )
        }
    }

    private static func detailsContent(
        for record: AgentToolUseRecord,
        events: [AgentRunEvent]
    ) -> StructuredContent {
        var sections: [StructuredContent] = [
            .group(
                role: "agentic.tool.call",
                title: [
                    .text("Call")
                ],
                content: .collection([
                    labeledContent(
                        "tool",
                        record.toolCall.name
                    ),
                    labeledContent(
                        "id",
                        record.toolCall.id
                    ),
                    labeledContent(
                        "disposition",
                        record.disposition.rawValue
                    ),
                ])
            ),
            .group(
                role: "agentic.tool.input",
                title: [
                    .text("Input")
                ],
                content: .code(
                    language: "json",
                    source: prettyEncoded(
                        record.toolCall.input
                    )
                )
            ),
        ]

        if let preflight = record.preflight {
            var content: [StructuredContent] = [
                labeledContent(
                    "risk",
                    preflight.risk.rawValue
                ),
                labeledContent(
                    "summary",
                    preflight.summary
                ),
            ]

            if let workspaceRoot = preflight.workspaceRoot {
                content.append(
                    labeledContent(
                        "workspace",
                        workspaceRoot
                    )
                )
            }

            if !preflight.targetPaths.isEmpty {
                content.append(
                    .group(
                        role: "agentic.tool.targets",
                        title: [
                            .text("Targets")
                        ],
                        content: .list(
                            style: .unordered,
                            items: preflight.targetPaths.map { path in
                                .paragraph([
                                    .text(path)
                                ])
                            }
                        )
                    )
                )
            }

            sections.append(
                .group(
                    role: "agentic.tool.preflight",
                    title: [
                        .text("Preflight")
                    ],
                    content: .collection(
                        content
                    )
                )
            )
        }

        if let result = record.result {
            var content: [StructuredContent] = [
                labeledContent(
                    "error",
                    String(result.isError)
                ),
            ]

            if let projection = result.processing?.projection {
                content.append(
                    labeledContent(
                        "status",
                        projection.status
                    )
                )

                if let summary = projection.summary {
                    content.append(
                        labeledContent(
                            "summary",
                            summary
                        )
                    )
                }

                if !projection.facts.isEmpty {
                    content.append(
                        .group(
                            role: "agentic.tool.facts",
                            title: [
                                .text("Facts")
                            ],
                            content: .collection(
                                projection.facts.map { fact in
                                    labeledContent(
                                        fact.label,
                                        fact.value
                                    )
                                }
                            )
                        )
                    )
                }
            }

            content.append(
                .group(
                    role: "agentic.tool.output",
                    title: [
                        .text("Output")
                    ],
                    content: .code(
                        language: "json",
                        source: prettyEncoded(
                            result.output
                        )
                    )
                )
            )

            sections.append(
                .group(
                    role: "agentic.tool.result",
                    title: [
                        .text("Result")
                    ],
                    content: .collection(
                        content
                    )
                )
            )

            let observations =
                result.processing?.observations
                    .filter {
                        $0.kind != .standard_output
                            && $0.kind != .standard_error
                    }
                    ?? []

            if !observations.isEmpty {
                sections.append(
                    .group(
                        role: "agentic.tool.observations",
                        title: [
                            .text("Observations")
                        ],
                        content: .list(
                            style: .unordered,
                            items: observations.map { observation in
                                labeledContent(
                                    observation.label
                                        ?? observation.kind.rawValue,
                                    observation.content
                                )
                            }
                        )
                    )
                )
            }
        }

        if !events.isEmpty {
            sections.append(
                .group(
                    role: "agentic.tool.events",
                    title: [
                        .text("Events")
                    ],
                    content: .list(
                        style: .unordered,
                        items: events.map { event in
                            .paragraph([
                                .code(
                                    "iteration \(event.iteration)"
                                ),
                                .text(
                                    "  \(event.kind.rawValue): \(event.summary)"
                                ),
                            ])
                        }
                    )
                )
            )
        }

        return .collection(
            sections
        )
    }

    private static func labeledContent(
        _ label: String,
        _ value: String
    ) -> StructuredContent {
        .paragraph([
            .strong([
                .text(label)
            ]),
            .text(
                "  \(value)"
            ),
        ])
    }

    private static func detailsBody(
        for record: AgentToolUseRecord,
        events: [AgentRunEvent]
    ) -> String {
        var sections: [String] = [
            [
                "Call",
                "tool         \(record.toolCall.name)",
                "id           \(record.toolCall.id)",
                "disposition  \(record.disposition.rawValue)",
            ].joined(separator: "\n"),
            [
                "Input",
                prettyEncoded(
                    record.toolCall.input
                ),
            ].joined(separator: "\n"),
        ]

        if let preflight = record.preflight {
            var lines = [
                "Preflight",
                "risk         \(preflight.risk.rawValue)",
                "summary      \(preflight.summary)",
            ]

            if let workspaceRoot = preflight.workspaceRoot {
                lines.append(
                    "workspace    \(workspaceRoot)"
                )
            }

            if !preflight.targetPaths.isEmpty {
                lines.append(
                    "targets      \(preflight.targetPaths.joined(separator: ", "))"
                )
            }

            sections.append(
                lines.joined(separator: "\n")
            )
        }

        if let result = record.result {
            var lines = [
                "Result",
                "error        \(result.isError)",
            ]

            if let projection = result.processing?.projection {
                lines.append(
                    "status       \(projection.status)"
                )

                if let summary = projection.summary {
                    lines.append(
                        "summary      \(summary)"
                    )
                }

                for fact in projection.facts {
                    lines.append(
                        "\(fact.label)  \(fact.value)"
                    )
                }
            }

            lines.append("")
            lines.append("Output")
            lines.append(
                prettyEncoded(
                    result.output
                )
            )

            sections.append(
                lines.joined(separator: "\n")
            )

            let observations =
                result.processing?.observations
                    .filter {
                        $0.kind != .standard_output
                            && $0.kind != .standard_error
                    }
                    ?? []

            if !observations.isEmpty {
                var lines = [
                    "Observations"
                ]

                for observation in observations {
                    lines.append(
                        "\(observation.label ?? observation.kind.rawValue)  \(observation.content)"
                    )
                }

                sections.append(
                    lines.joined(separator: "\n")
                )
            }
        }

        if !events.isEmpty {
            sections.append(
                (
                    ["Events"]
                        + events.map {
                            "[iteration \($0.iteration)] \($0.kind.rawValue): \($0.summary)"
                        }
                ).joined(separator: "\n")
            )
        }

        return sections.joined(
            separator: "\n\n"
        )
    }

    private static func prettyEncoded<T: Encodable>(
        _ value: T
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]

        guard
            let data = try? encoder.encode(
                value
            ),
            let text = String(
                data: data,
                encoding: .utf8
            )
        else {
            return String(
                describing: value
            )
        }

        return text
    }

    private static func runState(
        for phase: AgentHistoryPhase
    ) -> AgenticHostConsoleRunState {
        switch phase {
        case .ready_for_model,
             .receiving_model_response,
             .processing_tool_calls:
            return .active

        case .suspended,
             .interrupted:
            return .paused

        case .awaiting_approval:
            return .awaitingApproval

        case .failed:
            return .failed

        case .completed:
            return .completed
        }
    }

    private static func runState(
        for result: AgentRunResult
    ) -> AgenticHostConsoleRunState {
        if result.isFailed {
            return .failed
        }
        if result.isAwaitingApproval {
            return .awaitingApproval
        }
        if result.isSuspended {
            return .paused
        }
        return .completed
    }

    private static func stepState(
        for record: AgentToolUseRecord
    ) -> AgenticHostConsoleStepState {
        switch record.disposition {
        case .pending:
            return .pending

        case .preflighted,
             .suspended_for_approval,
             .suspended_for_user_input:
            return .active

        case .executed:
            return record.result?.isError == true
                ? .failed
                : .completed

        case .skipped_after_mutation,
             .skipped_after_denial,
             .skipped_by_user,
             .skipped_after_user_input:
            return .skipped

        case .failed_preflight,
             .failed_execution:
            return .failed
        }
    }

    private static func stepState(
        for events: [AgentRunEvent]
    ) -> AgenticHostConsoleStepState {
        if events.contains(where: {
            $0.kind == .tool_error
        }) {
            return .failed
        }
        if events.contains(where: {
            $0.kind == .tool_denied
                || $0.kind == .tool_skipped
        }) {
            return .skipped
        }
        if events.contains(where: {
            $0.kind == .tool_result
        }) {
            return .completed
        }
        return .active
    }
}
