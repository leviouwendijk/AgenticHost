import AgenticHost
import AgenticInterfaces
import AgenticPresentation
import AgenticRuntime
import AgenticStandard
import DSL
import ErrorsDSL
import Foundation
import Primitives
import Terminal

@_spi(Testing) public struct AgenticConversationRunProjection {
    public var run: AgenticHostConsoleRunPresentation
    public var documents: [AgenticHostConsoleDocumentPresentation]
    public var interruptions: [AgenticHostConsoleInterruptionPresentation]

    public static func project(
        _ state: AgentRunStateSnapshot,
        title: String,
        previous_trace: AgentExecutionTrace? = nil
    ) -> Self {
        var projection = project(
            AgentExecutor.Result(
                sessionID: state.sessionID,
                phase: state.phase,
                response: state.lastResponse,
                suspension: state.suspension,
                pendingApproval: state.pendingApproval,
                failure: state.failure,
                state: state.state,
                events: state.events,
                toolUses: state.toolUses,
                costRecord: state.costRecord,
                invocations: state.invocations ?? []
            ),
            title: title,
            previous_trace: previous_trace
        )

        projection.run.state = runState(
            for: state.phase
        )

        if projection.run.summary == nil {
            projection.run.summary = state.failure?.message
        }

        return projection
    }

    public static func project(
        _ result: AgentExecutor.Result,
        title: String,
        previous_trace: AgentExecutionTrace? = nil
    ) -> Self {
        let eventsByCallID = Dictionary(
            grouping: result.events.compactMap { event -> Run.Event.State? in
                event.callID == nil
                    ? nil
                    : event
            },
            by: { event in
                event.callID!
            }
        )

        var documents: [AgenticHostConsoleDocumentPresentation] = []
        var steps: [AgenticHostConsoleStepPresentation]
        // Calls made through `capabilities_tool_call` are recorded, and shown, as
        // the capability's own; this marks them.
        let dispatched = result.state.messages.dispatchedCallIDs

        if result.toolUses.isEmpty {
            steps = legacySteps(
                for: result,
                eventsByCallID: eventsByCallID,
                documents: &documents
            )
        } else {
            steps = result.toolUses.map { record in
                let callID = record.functionCall.id
                let events = eventsByCallID[callID] ?? []
                let state = stepState(for: record)
                let projection = record.result?.projection

                let via = dispatched.contains(callID)
                    ? Capabilities.Tools.Call.identifier.rawValue
                    : nil
                var fields: [AgenticHostConsoleField] = [
                    .init("outcome", state.rawValue),
                    .init("disposition", record.disposition.rawValue),
                ]
                if let via {
                    fields.append(.init("via", via))
                }

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
                            events: events,
                            via: via
                        ),
                        structuredBody: detailsContent(
                            for: record,
                            events: events,
                            via: via
                        )
                    )
                )

                // Every presentation is inspectable with its call, whether or
                // not it is also attached to the answer.
                if let presentation = record.presentation {
                    let view = AgenticConversationStructuredPresentation(
                        id: "\(result.sessionID)-\(callID)-view",
                        sourceCallID: callID,
                        iteration: nil,
                        content: .document(presentation.document)
                    )
                    documents.append(
                        .init(
                            id: view.id,
                            runID: result.sessionID,
                            stepID: callID,
                            kind: .details,
                            title: presentation.document.title,
                            body: view.rows(columns: 100).joined(separator: "\n"),
                            reportBody: presentation.document
                        )
                    )
                }

                if record.disposition == .executed || record.disposition == .failed_execution {
                    documents.append(contentsOf: ToolObservationPresentation.streams(
                        record.observations,
                        runID: result.sessionID,
                        stepID: callID,
                        prefix: "\(result.sessionID)-\(callID)"
                    ))
                }

                if let preview = record.preflight.flatMap({
                    HostPreviewDocument.make(
                        $0.preview,
                        id: "\(result.sessionID)-\(callID)-preview",
                        runID: result.sessionID,
                        stepID: callID
                    )
                }) {
                    documents.append(preview)
                }

                return .init(
                    id: callID,
                    title: record.functionCall.name,
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

        let runLimit = runLimitInterruption(
            for: result
        )

        if let runLimit {
            steps.append(
                runLimit.step
            )
        }

        let workspaceAccess = workspaceAccessInterruption(
            for: result
        )

        if let workspaceAccess {
            documents.removeAll { document in
                document.runID == result.sessionID
                    && document.stepID == workspaceAccess.interruption.stepID
                    && document.kind == .details
            }
            documents.append(
                workspaceAccess.details
            )
        }

        if !result.events.isEmpty || !result.toolUses.isEmpty || !result.invocations.isEmpty {
            let trace_step_id = "\(result.sessionID)-execution-trace"
            do {
                let trace = try result.execution_trace()
                func trace_node(
                    _ node: Primitives.Tree<AgentExecutionTraceNode>.Node
                ) -> AgenticHostConsoleTraceNode {
                    .init(
                        id: node.value.id,
                        title: node.value.title,
                        detail: node.value.detail,
                        reference_id: node.value.reference_id,
                        children: node.children.map(trace_node)
                    )
                }
                let navigation_nodes = trace.tree.roots.map(trace_node)
                let body = AgenticExecutionTreeRenderer.render(trace.tree) { node in
                    if let detail = node.detail, !detail.isEmpty {
                        return "\(node.title) · \(detail)"
                    }
                    return node.title
                }
                steps.insert(
                    .init(
                        id: trace_step_id,
                        title: "execution trace",
                        detail: "\(result.events.count) recorded run events",
                        state: result.phase == .completed ? .completed : .active,
                        fields: []
                    ),
                    at: 0
                )
                documents.append(.init(
                    id: "\(trace_step_id)-details",
                    runID: result.sessionID,
                    stepID: trace_step_id,
                    kind: .details,
                    title: "Execution trace",
                    body: body,
                    traceRoots: navigation_nodes
                ))
                if let previous_trace, previous_trace.id == trace.id,
                   previous_trace != trace {
                    let diff_body = AgenticExecutionTreeRenderer.render(
                        try trace.difference_layout(from: previous_trace)
                    )
                    documents.append(.init(
                        id: "\(trace_step_id)-difference",
                        runID: result.sessionID,
                        stepID: trace_step_id,
                        kind: .preview,
                        title: "Execution trace changes",
                        body: diff_body
                    ))
                }
            } catch {
                steps.insert(
                    .init(
                        id: trace_step_id,
                        title: "execution trace",
                        detail: "Trace projection failed: \(error)",
                        state: .failed,
                        fields: []
                    ),
                    at: 0
                )
                documents.append(.init(
                    id: "\(trace_step_id)-details",
                    runID: result.sessionID,
                    stepID: trace_step_id,
                    kind: .details,
                    title: "Execution trace error",
                    body: String(describing: error)
                ))
            }
        }
        documents += approvalDocuments(
            sessionID: result.sessionID,
            pendingApproval: result.pendingApproval,
            existing: documents
        )

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
                iteration: result.state.iteration,
                steps: steps
            ),
            documents: documents,
            interruptions:
                approvalInterruptions(
                    sessionID: result.sessionID,
                    pendingApproval: result.pendingApproval
                )
                + (
                    workspaceAccess.map { projection in
                        [
                            projection.interruption,
                        ]
                    } ?? []
                )
                + (
                    runLimit.map { projection in
                        [
                            projection.interruption,
                        ]
                    } ?? []
                )
        )
    }

    private static func runLimitInterruption(
        for result: AgentExecutor.Result
    ) -> (
        step: AgenticHostConsoleStepPresentation,
        interruption: AgenticHostConsoleInterruptionPresentation
    )? {
        guard let interaction = result.interactionRequest,
              interaction.kind == .run_limit,
              case .run_limit(let exhaustion) = interaction.requirement
        else {
            return nil
        }

        switch exhaustion {
        case .iterations(let limit, let consumed):
            let stepID = "\(interaction.id)-run-limit"
            let summary =
                "Iterations \(consumed) / \(limit). "
                + "The run is suspended before the next model turn."

            return (
                step: .init(
                    id: stepID,
                    title: "run limit",
                    detail: summary,
                    state: .warning,
                    fields: [
                        .init(
                            "iterations",
                            "\(consumed) / \(limit)"
                        ),
                    ],
                    groups: [
                        "runtime",
                        "run_limit",
                    ]
                ),
                interruption: .init(
                    id: interaction.id,
                    runID: result.sessionID,
                    stepID: stepID,
                    kind: .run_limit,
                    title: "Run limit reached",
                    summary: summary,
                    actions: [
                        .run_limit_continue(
                            iterations: consumed + 4
                        ),
                        .run_limit_continue(
                            iterations: consumed + 12
                        ),
                        .run_limit_unlimited,
                        .run_limit_stop,
                    ]
                )
            )

        case .context(let estimated, let limit, let compactable):
            let stepID = "\(interaction.id)-context-limit"
            return (
                step: .init(
                    id: stepID,
                    title: "context limit",
                    detail: exhaustion.summary,
                    state: .warning,
                    fields: [
                        .init("input", "≈\(estimated) / \(limit) tokens"),
                        .init("compactable", "≈\(compactable) tokens"),
                    ],
                    groups: [
                        "runtime",
                        "context",
                    ]
                ),
                interruption: .init(
                    id: interaction.id,
                    runID: result.sessionID,
                    stepID: stepID,
                    kind: .run_limit,
                    title: "Context limit reached",
                    summary: exhaustion.summary,
                    actions: (compactable > 0 ? [.compact_and_continue] : []) + [.run_limit_stop]
                )
            )
        }
    }

    private static func workspaceAccessInterruption(
        for result: AgentExecutor.Result
    ) -> (
        interruption: AgenticHostConsoleInterruptionPresentation,
        details: AgenticHostConsoleDocumentPresentation
    )? {
        guard let interaction = result.interactionRequest,
              interaction.kind == .workspace_access,
              case .workspace_access(let request) = interaction.requirement
        else {
            return nil
        }

        let stepID =
            result.toolUses.first(
                where: { record in
                    record.disposition == .suspended_for_workspace_access
                }
            )?.functionCall.id
            ?? result.events.last(
                where: { event in
                    event.kind == .pending_workspace_access
                }
            )?.callID
            ?? interaction.id

        return (
            interruption: .init(
                id: interaction.id,
                runID: result.sessionID,
                stepID: stepID,
                kind: .workspace_access,
                title: "Workspace access requested",
                summary: AgenticWorkspaceAccessPresentation.summary(
                    request
                ),
                actions: [
                    .grant_for_turn,
                    .grant_for_session,
                    .deny,
                ]
            ),
            details: .init(
                id: "\(interaction.id)-details",
                runID: result.sessionID,
                stepID: stepID,
                kind: .details,
                title: "Workspace access",
                body: AgenticWorkspaceAccessPresentation.details(
                    request
                )
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

        let stepID = pendingApproval.functionCall.id

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

    /// Review documents for the pending approval, from the approval itself:
    /// its preflight carries the exact prepared diff, also when a delegated
    /// worker raised it and this run has no tool record for the call. Kept
    /// under the approval's own step so the review finds them; skipped when
    /// a tool record already supplied them.
    private static func approvalDocuments(
        sessionID: String,
        pendingApproval: PendingApproval?,
        existing: [AgenticHostConsoleDocumentPresentation]
    ) -> [AgenticHostConsoleDocumentPresentation] {
        guard let pendingApproval else {
            return []
        }

        let stepID = pendingApproval.functionCall.id
        let present = Set(
            existing
                .filter { $0.runID == sessionID && $0.stepID == stepID }
                .map(\.kind)
        )
        let preview = pendingApproval.preflight.preview
        var documents: [AgenticHostConsoleDocumentPresentation] = []

        if !present.contains(.details) {
            documents.append(
                .init(
                    id: "\(sessionID)-\(stepID)-approval-details",
                    runID: sessionID,
                    stepID: stepID,
                    kind: .details,
                    title: "Approval details",
                    body: [
                        "tool     \(pendingApproval.functionCall.name)",
                        "call     \(stepID)",
                        "risk     \(pendingApproval.preflight.risk.rawValue)",
                        "summary  \(pendingApproval.preflight.summary)",
                        preview.isEmpty
                            ? "preview  not available: the prepared call carries no preview"
                            : "preview  see \(AgenticPreviewRenderer.title(preview.sections))",
                    ].joined(separator: "\n")
                )
            )
        }

        if !present.contains(.preview),
           let document = HostPreviewDocument.make(
               preview,
               id: "\(sessionID)-\(stepID)-approval-preview",
               runID: sessionID,
               stepID: stepID
           ) {
            documents.append(document)
        }

        return documents
    }

    private static func legacySteps(
        for result: AgentExecutor.Result,
        eventsByCallID: [String: [Run.Event.State]],
        documents: inout [AgenticHostConsoleDocumentPresentation]
    ) -> [AgenticHostConsoleStepPresentation] {
        var order: [String] = []

        for event in result.events {
            guard let callID = event.callID else {
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
        events: [Run.Event.State],
        via: String?
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
                        record.functionCall.name
                    ),
                ] + (via.map { [labeledContent("via", $0)] } ?? []) + [
                    labeledContent(
                        "id",
                        record.functionCall.id
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
                        record.functionCall.input
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

            if let workspaceRoot = preflight.access.roots.first {
                content.append(
                    labeledContent(
                        "workspace",
                        workspaceRoot
                    )
                )
            }

            if !preflight.access.targets.isEmpty {
                content.append(
                    .group(
                        role: "agentic.tool.targets",
                        title: [
                            .text("Targets")
                        ],
                        content: .list(
                            style: .unordered,
                            items: preflight.access.targets.map { path in
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

            if let projection = result.projection {
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

        let observations = ToolObservationPresentation.details(record.observations)
        if !observations.isEmpty {
            sections.append(.group(
                role: "agentic.tool.observations",
                title: [.text("Observations")],
                content: .paragraph([.text(observations)])
            ))
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
        events: [Run.Event.State],
        via: String?
    ) -> String {
        var sections: [String] = [
            [
                "Call",
                "tool         \(record.functionCall.name)" + (via.map { " (via \($0))" } ?? ""),
                "id           \(record.functionCall.id)",
                "disposition  \(record.disposition.rawValue)",
            ].joined(separator: "\n"),
            [
                "Input",
                prettyEncoded(
                    record.functionCall.input
                ),
            ].joined(separator: "\n"),
        ]

        if let preflight = record.preflight {
            var lines = [
                "Preflight",
                "risk         \(preflight.risk.rawValue)",
                "summary      \(preflight.summary)",
            ]

            if let workspaceRoot = preflight.access.roots.first {
                lines.append(
                    "workspace    \(workspaceRoot)"
                )
            }

            if !preflight.access.targets.isEmpty {
                lines.append(
                    "targets      \(preflight.access.targets.joined(separator: ", "))"
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

            if let projection = result.projection {
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

        let observations = ToolObservationPresentation.details(record.observations)
        if !observations.isEmpty {
            sections.append(observations)
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
        for phase: AgentExecutor.Phase
    ) -> AgenticHostConsoleRunState {
        switch phase {
        case .ready_for_model,
             .receiving_model_response,
             .processing_tool_calls:
            return .active

        case .suspended:
            return .paused

        case .interrupted:
            return .interrupted

        case .awaiting_approval:
            return .awaitingApproval

        case .failed:
            return .failed

        case .completed:
            return .completed
        }
    }

    private static func runState(
        for result: AgentExecutor.Result
    ) -> AgenticHostConsoleRunState {
        runState(
            for: result.phase
        )
    }

    private static func stepState(
        for record: AgentToolUseRecord
    ) -> AgenticHostConsoleStepState {
        switch record.disposition {
        case .pending:
            return .pending

        case .preflighted,
             .suspended_for_approval,
             .suspended_for_delegation,
             .suspended_for_user_input,
             .suspended_for_workspace_access:
            return .active

        case .executed:
            return record.result?.isError == true
                ? .failed
                : .completed

        case .skipped_after_mutation,
             .skipped_after_denial,
             .skipped_by_user,
             .skipped_after_user_input,
             .skipped_after_workspace_access,
             .deferred_for_review:
            return .skipped

        case .failed_preflight,
             .failed_execution:
            return .failed
        }
    }

    private static func stepState(
        for events: [Run.Event.State]
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
