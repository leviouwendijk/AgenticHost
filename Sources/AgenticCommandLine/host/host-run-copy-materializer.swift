import AgenticExecution
import AgenticInterfaces

package struct HostRunCopy: Sendable, Hashable {
    package let title: String
    package let text: String
}

package actor HostRunArtifacts {
    private var inputSourceByRunID: [String: String] = [:]

    package init() {}

    package func retainInput(
        _ source: String,
        runID: String
    ) {
        inputSourceByRunID[runID] = source
    }

    package func input(
        runID: String
    ) -> String? {
        inputSourceByRunID[runID]
    }
}

package enum HostRunCopyMaterializer {
    package static func materialize(
        _ event: AgenticHostConsoleWorkflowEvent,
        inputs: HostRunArtifacts,
        runs: [AgentToolPlanRun]
    ) async throws -> HostRunCopy? {
        switch event {
        case .runInputCopyRequested(
            runID: let runID
        ):
            guard let source = await inputs.input(
                runID: runID
            ) else {
                return nil
            }

            return HostRunCopy(
                title: "input",
                text: source
            )

        case .runOutputCopyRequested(
            runID: let runID
        ):
            guard let run = runs.first(
                where: {
                    $0.id == runID
                }
            ) else {
                return nil
            }

            return HostRunCopy(
                title: "output",
                text: try AgenticRuntimeCommandIO.text(
                    AgenticRuntimeBridgeRecovery.envelope(
                        for: run
                    )
                )
            )

        default:
            return nil
        }
    }
}
