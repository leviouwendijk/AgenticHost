import AgenticExecution
import AgenticIO
import AgenticRuntime
import AgenticWorkspace
import Agentic
import AgenticAWS
import AgenticInterfaces
import Foundation

enum AWSMutateRefactorApprovalTestCase {
    static func make() -> AgenticInterfaceTestCase {
        .init(
            id: "aws-mutate-refactor",
            summary: "Create aws-test.swift, let Claude read it, then stage a mutate_files refactor approval."
        ) { arguments in
            try await run(
                arguments
            )
        }
    }

    static func run(
        _ arguments: [String]
    ) async throws {
        let configuration = try AWSMutationApprovalConfiguration.parse(
            arguments
        )
        let workspaceRoot = try AgenticInterfaceTestEnvironment.workspaceRoot()
        let workspace = try AgentWorkspace(
            root: workspaceRoot
        )

        try AgenticInterfaceTestEnvironment.writeWorkspaceFile(
            AWSMutationRefactorFixture.content,
            to: configuration.targetPath
        )

        let mutateFilesTool = MutateFilesTool()

        var registry = ToolRegistry()
        try registry.register {
            ReadFileTool()
            mutateFilesTool
        }

        let historyStore = FileHistoryStore(
            sessionsdir: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agentic-interface-aws-mutate-refactor-\(UUID().uuidString)",
                    isDirectory: true
                )
        )

        // let presenter = TerminalAgenticRunPresenter()
        let presenter = AgenticInterfaceRuntimeFactory.presenter()

        let picker = TestFlowApprovalPicker(
            interaction: AgenticInterfaceTestEnvironment.interaction,
            presenter: presenter
        )

        print(
            "bedrock model: \(configuration.model)"
        )

        let adapter = try AgenticInterfaceRuntimeFactory.bedrockAdapter(
            metadata: [
                "source": "aginttest",
                "test_case": "aws-mutate-refactor",
            ]
        )

        // let adapter = try BedrockModelAdapter.resolve(
        //     defaultModelIdentifier: configuration.model,
        //     metadata: [
        //         "source": "aginttest",
        //         "test_case": "aws-mutate-refactor",
        //     ]
        // )

        let runner = AgentRunner(
            model: .init(
                invoker: IntegrationAdapterModelInvoker(
                    adapter: adapter,
                    model: configuration.model,
                    adapterIdentifier: .aws_bedrock
                )
            ),
            configuration: .init(
                maximumIterations: 12,
                autonomyMode: .auto_observe,
                historyPersistenceMode: .checkpointmutation,
                responseDelivery: .stream
            ),
            tooling: .init(
                registry: registry,
                workspace: workspace
            ),
            recording: .init(
                historyStore: historyStore
            )
        )

        let prompt = """
        Refactor \(configuration.targetPath).

        Required tool sequence:
        1. First call read_file for \(configuration.targetPath) with includeLineNumbers true. Do not ask me to paste the file.
        2. After reading the file, call mutate_files exactly once.
        3. The mutate_files call must contain exactly one entry.
        4. That entry must have kind "edit_text".
        5. That edit_text entry must include at least one insert_lines operation.
        6. Use insert_lines at position 5 to add a small private helper inside AWSFormatter, near the top of the struct after public init().
        7. In the same edit_text entry, use replace_lines to replace one complete trimming block with calls to that helper.
        8. Preserve all public function names and return formats.
        9. Do not use replace_line for multi-line content.
        10. For insert_lines, include position and lines.
        11. For replace_lines, include range and lines.
        12. For delete_lines, include range.
        13. Do not include expected, expectedLines, or read_file display gutters.
        14. The permitted replace_lines ranges are full original trimming blocks only: 11...16, 26...31, or 41...46.
        15. After one successful mutate_files result, stop calling tools and briefly summarize.

        Refactor request:
        Extract the repeated string trimming logic into one private helper and update at least one complete trimming site to use it. Keep the change small and reviewable.
        """

        try await presenter.present(
            .runStarted(
                prompt: prompt
            )
        )

        let initialResult = try await runner.run(
            AgentRequest(
                messages: [
                    .init(
                        role: .system,
                        text: """
                        You are a precise Swift refactoring agent.

                        You must use read_file before mutate_files.
                        Your single mutate_files call must contain exactly one edit_text entry.
                        That edit_text entry must include at least one insert_lines operation.
                        Use insert_lines at position 5 to add a private helper inside the existing type.
                        Use replace_lines only for existing code updates.
                        For replace_lines, replace one complete original trimming block only: 11...16, 26...31, or 41...46.
                        Do not use replace_line for multi-line content.
                        For insert_lines operations, include position and lines.
                        For replace_lines operations, include range and lines.
                        For delete_lines operations, include range.
                        Never include expected or expectedLines.
                        After one successful mutate_files result, stop calling tools and summarize.
                        Make one small reviewable edit.
                        """
                    ),
                    .init(
                        role: .user,
                        text: prompt
                    )
                ],
                generationConfiguration: .init(
                    maxOutputTokens: configuration.maxOutputTokens,
                    temperature: configuration.temperature
                )
            )
        )

        guard let pendingApproval = initialResult.pendingApproval else {
            try await presenter.present(
                initialResult
            )

            throw AWSMutateRefactorApprovalTestError.expectedApproval
        }

        guard pendingApproval.toolCall.name == mutateFilesTool.identifier.rawValue else {
            try await presenter.present(
                initialResult
            )

            throw AWSMutateRefactorApprovalTestError.expectedMutateApproval(
                pendingApproval.toolCall.name
            )
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
                title: "AWS Bedrock mutate_files refactor awaiting approval"
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
                    "summary": "approved AWS mutate_files refactor from aginttest terminal interface"
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
                    "summary": "denied AWS mutate_files refactor from aginttest terminal interface"
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
                    "summary": "skipped AWS mutate_files refactor from aginttest terminal interface"
                ]
            )

            try await presenter.present(
                resumed
            )

        case .stop_run:
            try await presenter.present(
                .runStopped(
                    reason: "User stopped the AWS mutate_files refactor run from the approval picker."
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

private enum AWSMutateRefactorApprovalTestError: Error, Sendable, LocalizedError {
    case expectedApproval
    case expectedMutateApproval(String)

    var errorDescription: String? {
        switch self {
        case .expectedApproval:
            return "Expected the AWS mutate refactor flow to suspend for mutate_files approval, but it did not."

        case .expectedMutateApproval(let toolName):
            return "Expected approval for mutate_files, but the pending tool was '\(toolName)'."
        }
    }
}
