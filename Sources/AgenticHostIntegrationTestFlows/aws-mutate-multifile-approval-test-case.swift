import AgenticExecution
import AgenticIO
import AgenticRuntime
import AgenticWorkspace
import Agentic
import AgenticAWS
import AgenticInterfaces
import Foundation

enum AWSMutateMultiFileApprovalTestCase {
    static func make() -> AgenticInterfaceTestCase {
        .init(
            id: "aws-mutate-multifile",
            summary: "Create two Swift files, read both, then stage one mutate_files approval across both files."
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
            AWSMultiFileMutationFixture.userFormatterContent,
            to: AWSMultiFileMutationFixture.userFormatterPath
        )

        try AgenticInterfaceTestEnvironment.writeWorkspaceFile(
            AWSMultiFileMutationFixture.dogFormatterContent,
            to: AWSMultiFileMutationFixture.dogFormatterPath
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
                    "agentic-interface-aws-mutate-multifile-\(UUID().uuidString)",
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
                "test_case": "aws-mutate-multifile",
            ]
        )

        // let adapter = try BedrockModelAdapter.resolve(
        //     defaultModelIdentifier: configuration.model,
        //     metadata: [
        //         "source": "aginttest",
        //         "test_case": "aws-mutate-multifile",
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
                maximumIterations: 16,
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
        Refactor two Swift files in one coherent mutate_files pass.

        Files:
        - \(AWSMultiFileMutationFixture.userFormatterPath)
        - \(AWSMultiFileMutationFixture.dogFormatterPath)

        Required tool sequence:
        1. First call read_file for \(AWSMultiFileMutationFixture.userFormatterPath) with includeLineNumbers true.
        2. Then call read_file for \(AWSMultiFileMutationFixture.dogFormatterPath) with includeLineNumbers true.
        3. Do not call mutate_files until both read_file calls have succeeded.
        4. After reading both files, call mutate_files exactly once.
        5. The mutate_files call must contain exactly two entries.
        6. The first entry must target \(AWSMultiFileMutationFixture.userFormatterPath), have kind "edit_text", and contain exactly two operations.
        7. The second entry must target \(AWSMultiFileMutationFixture.dogFormatterPath), have kind "edit_text", and contain exactly four operations.
        8. All operations must be line-oriented operations: insert_lines or replace_lines.
        9. For insert_lines, include position and lines.
        10. For replace_lines, include range and lines.
        11. Each item in lines must be one logical raw source line. Never put embedded newline characters inside a lines array string.
        12. Leading spaces are part of each lines array item. Preserve the exact Swift indentation required by the surrounding code.
        13. For private members inside the struct body, inserted source lines normally start with 4 spaces.
        14. For statements inside function bodies, replacement source lines normally start with 8 spaces.
        15. Do not include expected, expectedLines, or read_file display gutters.
        17. After one successful mutate_files result, stop calling tools and briefly summarize.

        Required edits in \(AWSMultiFileMutationFixture.userFormatterPath):
        - Operation 1: insert_lines at position 5 adding exactly these three raw source lines:
              "    private func trimString(_ string: String) -> String {"
              "        return string.trimmingCharacters(in: .whitespacesAndNewlines)"
              "    }"
        - Operation 2: replace_lines range 11...16 with exactly these two raw source lines:
              "        let trimmedName = trimString(name)"
              "        let trimmedCity = trimString(city)"

        Required edits in \(AWSMultiFileMutationFixture.dogFormatterPath):
        - Operation 1: insert_lines at position 5 adding exactly these three raw source lines:
              "    private func trimString(_ string: String) -> String {"
              "        return string.trimmingCharacters(in: .whitespacesAndNewlines)"
              "    }"
        - Operation 2: replace_lines range 11...16 with exactly these two raw source lines:
              "        let trimmedName = trimString(name)"
              "        let trimmedBreed = trimString(breed)"
        - Operation 3: replace_lines range 26...31 with exactly these two raw source lines:
              "        let trimmedClient = trimString(client)"
              "        let trimmedTopic = trimString(topic)"
        - Operation 4: replace_lines range 41...46 with exactly these two raw source lines:
              "        let trimmedStreet = trimString(street)"
              "        let trimmedCity = trimString(city)"

        Refactor request:
        Extract repeated trimming logic into a private helper in each file and update the specified trimming blocks. Keep the change small and reviewable.
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

                        Tool-call discipline:
                        Emit exactly one tool call per assistant response.
                        First call read_file for \(AWSMultiFileMutationFixture.userFormatterPath).
                        Then call read_file for \(AWSMultiFileMutationFixture.dogFormatterPath).
                        Only after both reads succeed, call mutate_files exactly once.
                        Never call mutate_files before both files have been read.

                        The single mutate_files call must contain exactly two edit_text entries.
                        Entry 1 must target \(AWSMultiFileMutationFixture.userFormatterPath) and contain exactly two operations.
                        Entry 2 must target \(AWSMultiFileMutationFixture.dogFormatterPath) and contain exactly four operations.

                        Use only insert_lines and replace_lines operations.
                        For insert_lines, include position and lines.
                        For replace_lines, include range and lines.
                        Each item in lines must be one logical raw source line with no newline characters.
                        Leading spaces are part of each lines array item.
                        Preserve the exact Swift indentation required by the surrounding code.
                        Private member lines inside these structs must start with 4 spaces.
                        Replacement statement lines inside function bodies must start with 8 spaces.
                        Never include expected or expectedLines.
                        Never copy read_file display gutters.

                        Use these exact original-coordinate ranges:
                        \(AWSMultiFileMutationFixture.userFormatterPath):
                        - insert_lines position 5
                        - replace_lines 11...16

                        \(AWSMultiFileMutationFixture.dogFormatterPath):
                        - insert_lines position 5
                        - replace_lines 11...16
                        - replace_lines 26...31
                        - replace_lines 41...46

                        The helper inserted in each file must be exactly:
                        "    private func trimString(_ string: String) -> String {"
                        "        return string.trimmingCharacters(in: .whitespacesAndNewlines)"
                        "    }"

                        After one successful mutate_files result, stop calling tools and summarize.
                        """
                    ),
                    .init(
                        role: .user,
                        text: prompt
                    )
                ],
                generationConfiguration: .init(
                    maxOutputTokens: max(
                        configuration.maxOutputTokens,
                        3000
                    ),
                    temperature: configuration.temperature
                )
            )
        )

        guard let pendingApproval = initialResult.pendingApproval else {
            try await presenter.present(
                initialResult
            )

            throw AWSMutateMultiFileApprovalTestError.expectedApproval
        }

        guard pendingApproval.toolCall.name == mutateFilesTool.identifier.rawValue else {
            try await presenter.present(
                initialResult
            )

            throw AWSMutateMultiFileApprovalTestError.expectedMutateApproval(
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
                title: "AWS Bedrock multi-file mutate_files refactor awaiting approval"
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
                    "summary": "approved AWS multi-file mutate_files refactor from aginttest terminal interface"
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
                    "summary": "denied AWS multi-file mutate_files refactor from aginttest terminal interface"
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
                    "summary": "skipped AWS multi-file mutate_files refactor from aginttest terminal interface"
                ]
            )

            try await presenter.present(
                resumed
            )

        case .stop_run:
            try await presenter.present(
                .runStopped(
                    reason: "User stopped the AWS multi-file mutate_files refactor run from the approval picker."
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

private enum AWSMultiFileMutationFixture {
    static let userFormatterPath = "aws-user-formatter.swift"
    static let dogFormatterPath = "aws-dog-formatter.swift"

    static let userFormatterContent = """
    import Foundation

    public struct AWSUserFormatter {
        public init() {}

        public func renderUser(
            name: String,
            city: String,
            score: Int
        ) -> String {
            let trimmedName = name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let trimmedCity = city.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            return "user=\\(trimmedName); city=\\(trimmedCity); score=\\(score)"
        }

        public func renderStatus(
            label: String,
            owner: String
        ) -> String {
            return "status=\\(label); owner=\\(owner)"
        }
    }

    """

    static let dogFormatterContent = """
    import Foundation

    public struct AWSDogFormatter {
        public init() {}

        public func renderDog(
            name: String,
            breed: String,
            age: Int
        ) -> String {
            let trimmedName = name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let trimmedBreed = breed.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            return "dog=\\(trimmedName); breed=\\(trimmedBreed); age=\\(age)"
        }

        public func renderClient(
            client: String,
            topic: String,
            hour: Int
        ) -> String {
            let trimmedClient = client.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let trimmedTopic = topic.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            return "client=\\(trimmedClient); topic=\\(trimmedTopic); hour=\\(hour)"
        }

        public func renderLocation(
            street: String,
            city: String,
            zip: String
        ) -> String {
            let trimmedStreet = street.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let trimmedCity = city.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            return "street=\\(trimmedStreet); city=\\(trimmedCity); zip=\\(zip)"
        }
    }

    """
}

private enum AWSMutateMultiFileApprovalTestError: Error, Sendable, LocalizedError {
    case expectedApproval
    case expectedMutateApproval(String)

    var errorDescription: String? {
        switch self {
        case .expectedApproval:
            return "Expected the AWS multi-file mutate refactor flow to suspend for mutate_files approval, but it did not."

        case .expectedMutateApproval(let toolName):
            return "Expected approval for mutate_files, but the pending tool was '\(toolName)'."
        }
    }
}
