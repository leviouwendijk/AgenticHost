import AgenticExecution
import AgenticInterfaces
import AgenticRuntime
import Terminal

enum AgenticRuntimeToolPlanRecoveryChoice:
    String,
    Sendable,
    Hashable,
    CaseIterable
{
    case retry
    case skip
    case continue_run
    case stop_run

    var title: String {
        switch self {
        case .retry:
            return "Retry failed step"

        case .skip:
            return "Skip failed step"

        case .continue_run:
            return "Continue parent plan"

        case .stop_run:
            return "Stop run"
        }
    }

    var summary: String {
        switch self {
        case .retry:
            return "Retry exactly the suspended ToolPlan node."

        case .skip:
            return "Resolve this node without executing it again."

        case .continue_run:
            return "Resume only the untouched parent-plan suffix."

        case .stop_run:
            return "Leave this ToolPlan suspended and return."
        }
    }
}

struct AgenticRuntimeToolPlanRecoveryPicker {
    var stream: TerminalStream = .standardError
    var theme: TerminalTheme = .agentic

    func pick(
        _ run: AgentToolPlanRun
    ) throws -> AgenticRuntimeToolPlanRecoveryChoice {
        guard case .suspended(let suspension) = run.state else {
            return .stop_run
        }

        let choices: [AgenticRuntimeToolPlanRecoveryChoice]
        let instructions: String

        switch suspension.reason {
        case .failure(let errorDescription):
            choices = [
                .retry,
                .skip,
                .stop_run,
            ]
            instructions =
                errorDescription
                ?? "The ToolPlan node failed."

        case .human_review:
            choices = [
                .retry,
                .skip,
                .stop_run,
            ]
            instructions =
                "The ToolPlan is suspended for human review."

        case .continuation_required:
            choices = [
                .continue_run,
                .stop_run,
            ]
            instructions =
                "The interrupted node is resolved. Continue only if the untouched suffix should execute."
        }

        let width = Terminal.size(
            for: stream
        ).columns
        let menu = TerminalInteractiveMenu<
            AgenticRuntimeToolPlanRecoveryChoice,
            String
        >(
            items: choices,
            configuration: .inline(
                title: "ToolPlan recovery · \(suspension.callID)",
                instructions: instructions,
                outputStream: stream,
                completionPresentation: .leaveSummary,
                currentRowStyle: .none
            ),
            id: { choice in
                choice.rawValue
            },
            row: { row in
                TerminalMenuRowContent(
                    title: row.item.title,
                    caption: row.item.summary
                ).render(
                    isCurrent: row.isCurrent,
                    isEnabled: row.isEnabled,
                    theme: theme,
                    width: width
                )
            },
            summary: { result in
                switch result {
                case .picked(let item, _):
                    return
                        "\(theme.label.apply("selected")) "
                        + "\(theme.value.apply(item.title))\n"

                case .cancelled:
                    return
                        "\(theme.label.apply("selected")) "
                        + "\(theme.warning.apply("Stop run"))\n"
                }
            }
        )

        switch try menu.run() {
        case .picked(let item, _):
            return item

        case .cancelled:
            return .stop_run
        }
    }
}

enum AgenticRuntimeBridgeRecovery {
    static func execute(
        _ request: AgenticToolHostRequest,
        host: AgenticToolHost,
        picker: AgenticRuntimeToolPlanRecoveryPicker?
    ) async throws -> AgenticToolHostEnvelope {
        guard request.action == .invoke,
              let plan = request.plan
        else {
            return try await host.execute(
                request
            )
        }

        let coordinator = AgentToolPlanRunCoordinator(
            invoker: host.invoker,
            context: host.context,
            approvalHandler: host.approvalHandler
        )
        var run = try await coordinator.start(
            plan
        )

        guard let picker else {
            return envelope(
                for: run
            )
        }

        while case .suspended = run.state {
            render(
                run
            )

            switch try picker.pick(
                run
            ) {
            case .retry:
                run = try await coordinator.retry(
                    runID: run.id,
                    expectedRevision: run.revision
                )

            case .skip:
                run = try await coordinator.skip(
                    runID: run.id,
                    expectedRevision: run.revision
                )

            case .continue_run:
                run = try await coordinator.resume(
                    runID: run.id,
                    expectedRevision: run.revision
                )

            case .stop_run:
                return envelope(
                    for: run
                )
            }
        }

        return envelope(
            for: run
        )
    }
}

extension AgenticRuntimeBridgeRecovery {
    static func render(
        _ run: AgentToolPlanRun
    ) {
        let rendered = TerminalToolHostReceiptRenderer(
            stream: .standardError
        ).render(
            envelope(
                for: run
            ),
            copiedToClipboard: false
        )

        guard !rendered.isEmpty else {
            return
        }

        Terminal.write(
            rendered + "\n",
            to: .standardError
        )
    }

    static func envelope(
        for run: AgentToolPlanRun
    ) -> AgenticToolHostEnvelope {
        AgenticToolHostEnvelope(
            action: .invoke,
            planResult: projectedResult(
                for: run
            )
        )
    }

    static func projectedResult(
        for run: AgentToolPlanRun
    ) -> AgentToolPlanResult {
        AgentToolPlanResult(
            planID: run.plan.id,
            outcome: projectedOutcome(
                for: run
            ),
            records: projectedRecords(
                for: run
            )
        )
    }

    static func projectedOutcome(
        for run: AgentToolPlanRun
    ) -> AgentToolPlanOutcome {
        switch run.state {
        case .completed:
            return .succeeded

        case .paused:
            return .mixed

        case .stopped(let outcome):
            return outcome

        case .suspended(let suspension):
            switch suspension.reason {
            case .failure:
                return .failed

            case .human_review:
                return .needs_human_review

            case .continuation_required:
                return .mixed
            }
        }
    }

    static func projectedRecords(
        for run: AgentToolPlanRun
    ) -> [AgentToolPlanRecord] {
        var orderedPaths: [String] = []
        var recordsByPath: [String: AgentToolPlanRecord] = [:]

        for attempt in run.attempts {
            for record in attempt.result.records {
                if recordsByPath[record.path] == nil {
                    orderedPaths.append(
                        record.path
                    )
                }

                recordsByPath[record.path] = record
            }
        }

        for resolution in run.resolutions {
            guard case .skipped = resolution.kind,
                  let record = recordsByPath[resolution.path]
            else {
                continue
            }

            recordsByPath[resolution.path] = AgentToolPlanRecord(
                path: resolution.path,
                call: record.call,
                outcome: .skipped,
                skipReason: "explicit_run_resolution"
            )
        }

        return orderedPaths.compactMap { path in
            recordsByPath[path]
        }
    }
}
