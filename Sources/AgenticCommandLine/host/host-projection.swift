import Agentic
import AgenticInterfaces
import AgenticRuntime
import Terminal

package enum HostProjection {
    package static func snapshot(
        runs: [ToolPlan.Run],
        context: String,
        note: String? = nil
    ) -> AgenticHostConsoleSnapshot {
        let context = [
            context,
            note,
        ]
            .compactMap { value in
                guard let value,
                      !value.isEmpty else {
                    return nil
                }

                return value
            }
            .joined(
                separator: " · "
            )

        return AgenticHostConsoleSnapshot(
            context: context,
            runs: runs.map(
                makeRun
            ),
            interruptions: runs.compactMap(
                makeInterruption
            ),
            documents: runs.flatMap(
                makeDocs
            )
        )
    }
}

private extension HostProjection {
    static func makeInterruption(
        _ run: ToolPlan.Run
    ) -> AgenticHostConsoleInterruptionPresentation? {
        guard case .interrupted(let interruption) = run.state else {
            return nil
        }

        let kind: AgenticHostConsoleInterruptionKind
        let title: String
        let summary: String
        let actions: [AgenticHostConsoleAction]

        switch interruption.reason {
        case .failure(let failure):
            kind = .recovery
            title = "Recovery"
            summary =
                failure.errorDescription
                ?? "The current ToolPlan step failed."
            actions = [
                .retry,
                .skip,
                .createFixBranch,
            ]

        case .human_review:
            kind = .approval
            title = "Approval"
            summary = "This ToolPlan step requires human approval."
            actions = [
                .approve,
                .deny,
                .skip,
            ]

        case .continuation_required:
            kind = .recovery
            title = "Continue"
            summary = "The interrupted step is resolved. Continue the remaining ToolPlan?"
            actions = [
                .continueRun,
            ]

        case .policy:
            kind = .recovery
            title = "Paused"
            summary = "ToolPlan execution is paused by policy."
            actions = [
                .continueRun,
            ]
        }

        return AgenticHostConsoleInterruptionPresentation(
            id: "\(run.id):\(run.revision)",
            runID: run.id,
            stepID: interruption.point.callID,
            kind: kind,
            title: title,
            summary: summary,
            actions: actions
        )
    }

    static func makeRun(
        _ run: ToolPlan.Run
    ) -> AgenticHostConsoleRunPresentation {
        let recordsByPath = Dictionary(
            uniqueKeysWithValues: records(
                run
            ).map { record in
                (
                    record.path,
                    record
                )
            }
        )

        return AgenticHostConsoleRunPresentation(
            id: run.id,
            title: run.plan.id,
            summary: summary(
                run
            ),
            state: state(
                run
            ),
            steps: steps(
                run.plan.root,
                path: "root",
                recordsByPath: recordsByPath
            )
        )
    }

    static func steps(
        _ node: ToolPlan.Node,
        path: String,
        recordsByPath: [String: ToolPlan.Record],
        groups: [String] = []
    ) -> [AgenticHostConsoleStepPresentation] {
        switch node {
        case .call(
            let call,
            _,
            let onSuccess,
            let onFailure,
            let onDenied
        ):
            let current: AgenticHostConsoleStepPresentation

            if let record = recordsByPath[path] {
                current = makeStep(
                    record,
                    groups: groups
                )
            } else {
                current = AgenticHostConsoleStepPresentation(
                    id: call.id,
                    title: call.tool.rawValue,
                    state: .pending,
                    groups: groups
                )
            }

            var result = [
                current,
            ]
            let branches: [
                (
                    nodes: [ToolPlan.Node],
                    path: String,
                    label: String
                )
            ] = [
                (
                    nodes: onSuccess,
                    path: "\(path).onSuccess",
                    label: "on success"
                ),
                (
                    nodes: onFailure,
                    path: "\(path).onFailure",
                    label: "on failure"
                ),
                (
                    nodes: onDenied,
                    path: "\(path).onDenied",
                    label: "on denied"
                ),
            ]

            for branch in branches where hasActivatedRecord(
                under: branch.path,
                recordsByPath: recordsByPath
            ) {
                result.append(
                    contentsOf: steps(
                        branch.nodes,
                        path: branch.path,
                        recordsByPath: recordsByPath,
                        groups: groups + [
                            branch.label,
                        ]
                    )
                )
            }

            return result

        case .sequence(let children):
            return steps(
                children,
                path: "\(path).sequence",
                recordsByPath: recordsByPath,
                groups: groups
            )

        case .batch(let children):
            return steps(
                children,
                path: "\(path).batch",
                recordsByPath: recordsByPath,
                groups: groups
            )
        }
    }

    static func steps(
        _ nodes: [ToolPlan.Node],
        path: String,
        recordsByPath: [String: ToolPlan.Record],
        groups: [String] = []
    ) -> [AgenticHostConsoleStepPresentation] {
        nodes.enumerated().flatMap { index, node in
            steps(
                node,
                path: "\(path)[\(index)]",
                recordsByPath: recordsByPath,
                groups: groups
            )
        }
    }

    static func hasActivatedRecord(
        under path: String,
        recordsByPath: [String: ToolPlan.Record]
    ) -> Bool {
        recordsByPath.contains {
            recordPath,
            record in

            (
                recordPath == path
                    || recordPath.hasPrefix(
                        path + "["
                    )
                    || recordPath.hasPrefix(
                        path + "."
                    )
            )
                && record.skipReason != "condition_not_selected"
        }
    }

    static func makeStep(
        _ record: ToolPlan.Record,
        groups: [String]
    ) -> AgenticHostConsoleStepPresentation {
        let review = record.invocation?.review
        let projection =
            record.invocation?
                .execution?
                .result
                .projection
        let targets = review?.preflight.access.targets ?? []
        let detail = targets.first.map { first in
            targets.count > 1
                ? "\(first) (+\(targets.count - 1))"
                : first
        }

        var fields = [
            AgenticHostConsoleField(
                "outcome",
                outcome(
                    record.outcome
                )
            ),
        ]

        if let invocation = record.invocation {
            fields.append(
                .init(
                    "decision",
                    invocation.decision.rawValue
                )
            )
        }

        if let projection {
            fields.append(
                .init(
                    "operation",
                    projection.status
                )
            )
        }

        if let review {
            let preflight = review.preflight

            fields.append(
                .init(
                    "requirement",
                    review.requirement.rawValue
                )
            )
            fields.append(
                .init(
                    "risk",
                    preflight.risk.rawValue
                )
            )

            if !targets.isEmpty {
                fields.append(
                    .init(
                        targets.count == 1
                            ? "target"
                            : "targets",
                        targets.joined(
                            separator: ", "
                        )
                    )
                )
            }

            if projection?.summary == nil,
               !preflight.summary.isEmpty
            {
                fields.append(
                    .init(
                        "summary",
                        preflight.summary
                    )
                )
            }

            if let difference = preflight.preview.difference {
                fields.append(
                    .init(
                        "changes",
                        "+\(difference.layout.changes.insertions.count) -\(difference.layout.changes.deletions.count)"
                    )
                )
            }
        }

        if let summary = projection?.summary,
           !summary.isEmpty
        {
            fields.append(
                .init(
                    "summary",
                    summary
                )
            )
        }

        if let projection {
            fields.append(
                contentsOf:
                    projection.facts.map { fact in
                        .init(
                            fact.label,
                            fact.value
                        )
                    }
            )
        }

        if let error = record.errorDescription,
           !error.isEmpty {
            fields.append(
                .init(
                    "error",
                    error
                )
            )
        }

        if let reason = record.skipReason,
           !reason.isEmpty {
            fields.append(
                .init(
                    "skip",
                    reason
                )
            )
        }

        return AgenticHostConsoleStepPresentation(
            id: record.call.id,
            title: record.call.tool.rawValue,
            detail: detail,
            state: state(
                record.outcome
            ),
            fields: fields,
            groups: groups
        )
    }

    static func makeDocs(
        _ run: ToolPlan.Run
    ) -> [AgenticHostConsoleDocumentPresentation] {
        records(
            run
        ).flatMap { record -> [AgenticHostConsoleDocumentPresentation] in
            guard let invocation = record.invocation else {
                return []
            }

            let review = invocation.review
            let preflight = review.preflight
            let inspection = preflight.inspectionDocument(
                title: "Staged intent details",
                toolName: record.call.tool.rawValue,
                toolCallID: record.call.id,
                requirement: review.requirement
            )
            var details = AgenticTerminalInspectionRenderer.render(
                inspection,
                stream: .standardError,
                theme: .agentic,
                layout: .agentic
            )

            if let execution = invocation.execution {
                let observations = ToolObservationPresentation.details(execution.observations)
                if !observations.isEmpty {
                    details += "\n\n" + observations
                }
            }

            var docs = [
                AgenticHostConsoleDocumentPresentation(
                    id: "\(run.id):\(record.call.id):details",
                    runID: run.id,
                    stepID: record.call.id,
                    kind: .details,
                    title: "Staged intent details",
                    body: details
                ),
            ]

            if let difference = preflight.preview.difference,
               !difference.isEmpty {
                let body = TerminalDifferenceRenderer.render(
                    difference.layout
                )

                let provenance: String

                if review.requirement == .needs_human_review {
                    provenance = "staged for approval"
                } else {
                    provenance = "execution review"
                }

                docs.append(
                    AgenticHostConsoleDocumentPresentation(
                        id: "\(run.id):\(record.call.id):diff",
                        runID: run.id,
                        stepID: record.call.id,
                        kind: .diff,
                        title: difference.title ?? "Diff preview",
                        body: [
                            "status     \(provenance)",
                            "",
                            body,
                        ].joined(
                            separator: "\n"
                        )
                    )
                )
            }

            if let execution = invocation.execution {
                docs.append(contentsOf: ToolObservationPresentation.streams(
                    execution.observations,
                    runID: run.id,
                    stepID: record.call.id,
                    prefix: "\(run.id):\(record.call.id)"
                ))
            }
            return docs
        }
    }

    static func summary(
        _ run: ToolPlan.Run
    ) -> String {
        let relationship: String

        switch run.relationship {
        case .root:
            relationship = "root"

        case .recovery(
            parentRunID: let parentID
        ):
            relationship = "recovery of \(parentID)"
        }

        let identity =
            "\(relationship) · rev \(run.revision)"

        guard !run.attempts.isEmpty else {
            return identity
        }

        let result =
            AgenticRuntimeBridgeRecovery.projectedResult(
                for: run
            )

        return [
            identity,
            result.outcome.rawValue,
            "\(result.executedCount) executed",
            "\(result.skippedCount) skipped",
        ].joined(
            separator: " · "
        )
    }

    static func state(
        _ run: ToolPlan.Run
    ) -> AgenticHostConsoleRunState {
        switch run.state {
        case .terminal(let outcome):
            switch outcome {
            case .succeeded:
                return .completed

            default:
                return .failed
            }

        case .interrupted(let interruption):
            switch interruption.reason {
            case .human_review:
                return .awaitingApproval

            case .failure:
                return .onHold

            case .continuation_required,
                 .policy:
                return .paused
            }
        }
    }

    static func state(
        _ outcome: ToolPlan.Outcome
    ) -> AgenticHostConsoleStepState {
        switch outcome {
        case .succeeded:
            return .completed

        case .needs_human_review:
            return .active

        case .skipped:
            return .skipped

        case .failed,
             .denied,
             .mixed:
            return .failed
        }
    }

    static func outcome(
        _ outcome: ToolPlan.Outcome
    ) -> String {
        switch outcome {
        case .succeeded:
            return "succeeded"

        case .failed:
            return "failed"

        case .denied:
            return "denied"

        case .needs_human_review:
            return "needs human review"

        case .skipped:
            return "skipped"

        case .mixed:
            return "mixed"
        }
    }

    static func shouldReplaceProjectedRecord(
        _ existing: ToolPlan.Record,
        with candidate: ToolPlan.Record
    ) -> Bool {
        guard candidate.skipReason == "condition_not_selected",
              existing.skipReason != "condition_not_selected"
        else {
            return true
        }

        return false
    }

    static func records(
        _ run: ToolPlan.Run
    ) -> [ToolPlan.Record] {
        var paths: [String] = []
        var byPath: [String: ToolPlan.Record] = [:]

        for attempt in run.attempts {
            for record in attempt.result.records {
                if byPath[record.path] == nil {
                    paths.append(
                        record.path
                    )
                }

                if let existing = byPath[record.path],
                   !shouldReplaceProjectedRecord(
                    existing,
                    with: record
                   )
                {
                    continue
                }

                byPath[record.path] = record
            }
        }

        for resolution in run.resolutions {
            guard case .skipped = resolution.kind,
                  let record = byPath[resolution.path]
            else {
                continue
            }

            byPath[resolution.path] = ToolPlan.Record(
                path: resolution.path,
                call: record.call,
                outcome: .skipped,
                invocation: record.invocation,
                skipReason: "explicit_run_resolution"
            )
        }

        return paths.compactMap { path in
            byPath[path]
        }
    }
}
