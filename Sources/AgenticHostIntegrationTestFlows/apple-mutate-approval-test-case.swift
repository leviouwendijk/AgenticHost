import Agentic
import AgenticExecution
import AgenticIO
import AgenticInterfaces
import AgenticRuntime
import AgenticWorkspace
import Foundation

enum AppleMutateApprovalTestCase {
    static func make() -> AgenticInterfaceTestCase {
        .init(
            id: "apple-mutate",
            summary: "Generate an Apple fragment, stage mutate_files, and use the terminal approval picker."
        ) { arguments in
            try await run(
                arguments
            )
        }
    }

    static func run(
        _ arguments: [String]
    ) async throws {
        let configuration = try AppleMutationApprovalConfiguration.parse(
            arguments
        )
        let workspaceRoot = try AgenticInterfaceTestEnvironment.workspaceRoot()
        let workspace = try AgentWorkspace(
            root: workspaceRoot
        )

        try AgenticInterfaceTestEnvironment.writeWorkspaceFile(
            FileContentComposer.seed(
                workspaceRoot: workspaceRoot,
                mutationToolName: MutateFilesTool.identifier.rawValue
            ),
            to: configuration.targetPath
        )

        let generatedMiddle = try await AppleStructuredQuoteGenerator().generateMiddleFragment()
        let middleLines = FileContentComposer.middleLines(
            generatedMiddle
        )
        let prompt = "replace only the Apple-generated middle fragment in \(configuration.targetPath) using mutate_files"

        var registry = ToolRegistry()
        try registry.register(
            MutateFilesTool()
        )

        let historyStore = FileHistoryStore(
            sessionsdir: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agentic-interface-test-apple-mutate-\(UUID().uuidString)",
                    isDirectory: true
                )
        )

        // let presenter = TerminalAgenticRunPresenter()
        let presenter = AgenticInterfaceRuntimeFactory.presenter()

        let picker = TestFlowApprovalPicker(
            interaction: AgenticInterfaceTestEnvironment.interaction,
            presenter: presenter
        )

        let runner = AgentRunner(
            model: .init(
                invoker: IntegrationGatewayModelInvoker(
                    gateway: ScriptedMutateWriteModelGateway(
                        path: configuration.targetPath,
                        middleLines: middleLines
                    ),
                    model: "scripted-mutate-write"
                )
            ),
            configuration: .init(
                maximumIterations: 4,
                autonomyMode: .auto_observe,
                historyPersistenceMode: .checkpointmutation
            ),
            tooling: .init(
                registry: registry,
                workspace: workspace
            ),
            recording: .init(
                historyStore: historyStore
            )
        )

        try await presenter.present(
            .runStarted(
                prompt: prompt
            )
        )

        let initialResult = try await runner.run(
            AgentRequest(
                messages: [
                    .init(
                        role: .user,
                        text: prompt
                    )
                ]
            )
        )

        guard let pendingApproval = initialResult.pendingApproval else {
            try await presenter.present(
                initialResult
            )

            try await presenter.present(
                .runCompleted(
                    summary: "Run did not suspend for approval."
                )
            )
            return
        }

        guard pendingApproval.toolCall.name == MutateFilesTool.identifier.rawValue else {
            try await presenter.present(
                initialResult
            )

            try await presenter.present(
                .runCompleted(
                    summary: "Expected mutate_files approval, got \(pendingApproval.toolCall.name)."
                )
            )
            return
        }

        try await presenter.present(
            .toolCallProposed(
                pendingApproval.toolCall
            )
        )

        try await presenter.present(
            .toolPreflight(
                pendingApproval.preflight
            )
        )

        try await presenter.present(
            initialResult
        )

        let choice = try await picker.pick(
            AgenticApprovalPrompt(
                pendingApproval: pendingApproval,
                title: "Runtime suspended for mutate_files approval"
            )
        )

        switch choice {
        case .approve:
            try await presenter.present(
                .approvalDecision(
                    .approved
                )
            )

            let resumed = try await runner.resume(
                sessionID: initialResult.sessionID,
                approvalDecision: ApprovalDecision.approved,
                metadata: [
                    "summary": "approved apple mutate_files from aginttest terminal interface"
                ]
            )

            try await presenter.present(
                resumed
            )

        case .deny:
            try await presenter.present(
                .approvalDecision(
                    .denied
                )
            )

            let resumed = try await runner.resume(
                sessionID: initialResult.sessionID,
                approvalDecision: ApprovalDecision.denied,
                metadata: [
                    "summary": "denied apple mutate_files from aginttest terminal interface"
                ]
            )

            try await presenter.present(
                resumed
            )

        case .skip:
            try await presenter.present(
                .approvalDecision(
                    .skipped
                )
            )

            let resumed = try await runner.resume(
                sessionID: initialResult.sessionID,
                approvalDecision: ApprovalDecision.skipped,
                metadata: [
                    "summary": "skipped from aginttest terminal interface"
                ]
            )

            try await presenter.present(
                resumed
            )

        case .stop_run:
            try await presenter.present(
                .runStopped(
                    reason: "User stopped the run from the approval picker."
                )
            )

        case .inspect_details,
             .show_diff:
            try await presenter.present(
                .runStopped(
                    reason: "Unexpected non-terminal picker choice escaped picker loop."
                )
            )
        }
    }
}
