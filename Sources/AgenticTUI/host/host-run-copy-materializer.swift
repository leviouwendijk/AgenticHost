import Agentic
import AgenticCommandLine
import AgenticInterfaces

@_spi(Testing) public struct HostRunCopy: Sendable, Hashable {
    package let title: String
    public let text: String
}

@_spi(Testing) public actor HostRunArtifacts {
    private var inputSourceByRunID: [String: String] = [:]

    @_spi(Testing) public init() {}

    public func retainInput(
        _ source: String,
        runID: String
    ) {
        inputSourceByRunID[runID] = source
    }

    public func input(
        runID: String
    ) -> String? {
        inputSourceByRunID[runID]
    }
}

@_spi(Testing) public enum HostRunCopyMaterializer {
    public static func materialize(
        _ event: AgenticHostConsoleWorkflowEvent,
        inputs: HostRunArtifacts,
        runs: [ToolPlan.Run]
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
                text: try AgenticCommandLineIO.text(
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
