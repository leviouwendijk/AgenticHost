import AgenticExecution
import AgenticIO
import AgenticRuntime
import AgenticWorkspace
import Agentic
import AgenticInterfaces
import Foundation

enum ScriptedProjectDiscoveryApprovalTestCase {
    static func make() -> AgenticInterfaceTestCase {
        .init(
            id: "scripted-project-discovery",
            summary: "Script scan/read/read/mutate_files against a temp project fixture, verify hidden .env read rejection, and ask approval for mutation."
        ) { _ in
            try await run()
        }
    }

    static func run() async throws {
        let tempWorkspace = try TempProjectWorkspace(
            root: try AgenticInterfaceTestEnvironment.workspaceRoot(),
            clean: false
        )

        try ProjectDiscoveryTempFixture.install(
            in: tempWorkspace
        )

        let userFormatterBefore = try tempWorkspace.read(
            ProjectDiscoveryTempFixture.userFormatterPath
        )
        let dogFormatterBefore = try tempWorkspace.read(
            ProjectDiscoveryTempFixture.dogFormatterPath
        )
        let envBefore = try tempWorkspace.read(
            ProjectDiscoveryTempFixture.envPath
        )
        let agenticStateBefore = try tempWorkspace.read(
            ProjectDiscoveryTempFixture.agenticStatePath
        )

        let workspace = try AgentWorkspace(
            root: tempWorkspace.root
        )

        var registry = ToolRegistry()
        try registry.register(
            ScanPathsTool()
        )
        try registry.register(
            ReadFileTool()
        )
        try registry.register(
            MutateFilesTool()
        )

        let historyStore = FileHistoryStore(
            sessionsdir: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agentic-interface-project-discovery-\(UUID().uuidString)",
                    isDirectory: true
                )
        )

        let presenter = TerminalAgenticRunPresenter()
        let picker = TestFlowApprovalPicker(
            interaction: AgenticInterfaceTestEnvironment.interaction,
            presenter: presenter
        )
        let trace = ProjectDiscoveryTrace()

        await trace.recordText(
            title: "temporary workspace",
            text: tempWorkspace.root.path
        )

        await trace.recordText(
            title: "fixture before: \(ProjectDiscoveryTempFixture.userFormatterPath)",
            text: userFormatterBefore
        )

        await trace.recordText(
            title: "fixture before: \(ProjectDiscoveryTempFixture.dogFormatterPath)",
            text: dogFormatterBefore
        )

        let runner = AgentRunner(
            model: .init(
                invoker: IntegrationAdapterModelInvoker(
                    adapter: ScriptedProjectDiscoveryModelAdapter(
                        userFormatterPath: ProjectDiscoveryTempFixture.userFormatterPath,
                        dogFormatterPath: ProjectDiscoveryTempFixture.dogFormatterPath,
                        trace: trace
                    ),
                    model: "scripted-project-discovery"
                )
            ),
            configuration: .init(
                maximumIterations: 10,
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

        let prompt = """
        Refactor duplicated string trimming logic in this project.

        You are not being given file names up front.
        Discover project files, read what you think is relevant, and then stage one coherent mutate_files pass.
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
                        You are a precise Swift project refactoring agent.

                        Required tool sequence:
                        1. First call scan_paths recursively in the current project root with hidden entries enabled.
                        2. Then make one speculative read_file call against the discovered hidden .env path, so the runtime sandbox can reject it if protected.
                        3. Continue after that denial by reading the relevant formatter source file.
                        4. Then read the second relevant formatter source file.
                        5. After both formatter reads have succeeded, call mutate_files exactly once.
                        6. Never call mutate_files before both formatter files have been read.
                        7. After one successful mutate_files result, stop calling tools and summarize.
                        """
                    ),
                    .init(
                        role: .user,
                        text: prompt
                    ),
                ]
            )
        )

        guard await trace.didRecordToolResult(
            id: ScriptedProjectDiscoveryModelResponseProvider.envReadToolCallID
        ) else {
            try await presenter.present(
                initialResult
            )

            throw ScriptedProjectDiscoveryTestError.expectedEnvReadAttempt
        }

        guard await trace.didRejectToolCall(
            id: ScriptedProjectDiscoveryModelResponseProvider.envReadToolCallID
        ) else {
            try await presenter.present(
                initialResult
            )

            throw ScriptedProjectDiscoveryTestError.expectedEnvReadRejection
        }

        guard let pendingApproval = initialResult.pendingApproval else {
            try await presenter.present(
                initialResult
            )

            throw ScriptedProjectDiscoveryTestError.expectedApproval
        }

        guard pendingApproval.toolCall.name == MutateFilesTool.identifier.rawValue else {
            try await presenter.present(
                initialResult
            )

            throw ScriptedProjectDiscoveryTestError.expectedMutateApproval(
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
                title: "Project discovery mutate_files refactor awaiting approval"
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
                approvalDecision: .approved,
                metadata: [
                    "summary": "approved scripted project discovery mutate_files pass"
                ]
            )

            guard resumed.isCompleted else {
                try await presenter.present(
                    resumed
                )

                throw ScriptedProjectDiscoveryTestError.expectedCompletion
            }

            try assertMutatedFormatterFiles(
                in: tempWorkspace
            )

            try assertEqual(
                try tempWorkspace.read(
                    ProjectDiscoveryTempFixture.envPath
                ),
                envBefore,
                "hidden .env fixture must remain unchanged"
            )

            try assertEqual(
                try tempWorkspace.read(
                    ProjectDiscoveryTempFixture.agenticStatePath
                ),
                agenticStateBefore,
                "hidden .agentic state fixture must remain unchanged"
            )

            await trace.recordText(
                title: "fixture after approval: \(ProjectDiscoveryTempFixture.userFormatterPath)",
                text: try tempWorkspace.read(
                    ProjectDiscoveryTempFixture.userFormatterPath
                )
            )

            await trace.recordText(
                title: "fixture after approval: \(ProjectDiscoveryTempFixture.dogFormatterPath)",
                text: try tempWorkspace.read(
                    ProjectDiscoveryTempFixture.dogFormatterPath
                )
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
                approvalDecision: .denied,
                metadata: [
                    "summary": "denied scripted project discovery mutate_files pass"
                ]
            )

            try assertEqual(
                try tempWorkspace.read(
                    ProjectDiscoveryTempFixture.userFormatterPath
                ),
                userFormatterBefore,
                "user formatter must remain unchanged after denial"
            )

            try assertEqual(
                try tempWorkspace.read(
                    ProjectDiscoveryTempFixture.dogFormatterPath
                ),
                dogFormatterBefore,
                "dog formatter must remain unchanged after denial"
            )

            try assertEqual(
                try tempWorkspace.read(
                    ProjectDiscoveryTempFixture.envPath
                ),
                envBefore,
                "hidden .env fixture must remain unchanged"
            )

            try assertEqual(
                try tempWorkspace.read(
                    ProjectDiscoveryTempFixture.agenticStatePath
                ),
                agenticStateBefore,
                "hidden .agentic state fixture must remain unchanged"
            )

            await trace.recordText(
                title: "fixture after denial: \(ProjectDiscoveryTempFixture.userFormatterPath)",
                text: try tempWorkspace.read(
                    ProjectDiscoveryTempFixture.userFormatterPath
                )
            )

            await trace.recordText(
                title: "fixture after denial: \(ProjectDiscoveryTempFixture.dogFormatterPath)",
                text: try tempWorkspace.read(
                    ProjectDiscoveryTempFixture.dogFormatterPath
                )
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
                approvalDecision: .skipped,
                metadata: [
                    "summary": "skipped scripted project discovery mutate_files pass"
                ]
            )

            try await presenter.present(
                resumed
            )

        case .stop_run:
            try await presenter.present(
                .runStopped(
                    reason: "User stopped the project discovery mutate_files run from the approval picker."
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

private extension ScriptedProjectDiscoveryApprovalTestCase {
    static func assertMutatedFormatterFiles(
        in workspace: TempProjectWorkspace
    ) throws {
        let userFormatter = try workspace.read(
            ProjectDiscoveryTempFixture.userFormatterPath
        )

        let dogFormatter = try workspace.read(
            ProjectDiscoveryTempFixture.dogFormatterPath
        )

        try assertContains(
            userFormatter,
            "    private func trimString(_ string: String) -> String {",
            "user formatter helper was not inserted"
        )

        try assertContains(
            userFormatter,
            "        let trimmedName = trimString(name)",
            "user formatter name trim call was not routed through helper"
        )

        try assertContains(
            userFormatter,
            "        let trimmedCity = trimString(city)",
            "user formatter city trim call was not routed through helper"
        )

        try assertContains(
            dogFormatter,
            "    private func trimString(_ string: String) -> String {",
            "dog formatter helper was not inserted"
        )

        try assertContains(
            dogFormatter,
            "        let trimmedName = trimString(name)",
            "dog formatter name trim call was not routed through helper"
        )

        try assertContains(
            dogFormatter,
            "        let trimmedBreed = trimString(breed)",
            "dog formatter breed trim call was not routed through helper"
        )

        try assertOccurrenceCount(
            userFormatter,
            ".trimmingCharacters(",
            expected: 1,
            "user formatter should contain only the helper trimming call"
        )

        try assertOccurrenceCount(
            dogFormatter,
            ".trimmingCharacters(",
            expected: 1,
            "dog formatter should contain only the helper trimming call"
        )

        try assertDoesNotContain(
            userFormatter,
            "let trimmedName = name\n            .trimmingCharacters(",
            "user formatter still contains the original name trimming block"
        )

        try assertDoesNotContain(
            userFormatter,
            "let trimmedCity = city\n            .trimmingCharacters(",
            "user formatter still contains the original city trimming block"
        )

        try assertDoesNotContain(
            dogFormatter,
            "let trimmedName = name\n            .trimmingCharacters(",
            "dog formatter still contains the original name trimming block"
        )

        try assertDoesNotContain(
            dogFormatter,
            "let trimmedBreed = breed\n            .trimmingCharacters(",
            "dog formatter still contains the original breed trimming block"
        )
    }

    static func assertContains(
        _ haystack: String,
        _ needle: String,
        _ message: String
    ) throws {
        guard haystack.contains(
            needle
        ) else {
            throw ScriptedProjectDiscoveryTestError.expectedMutation(
                message
            )
        }
    }

    static func assertDoesNotContain(
        _ haystack: String,
        _ needle: String,
        _ message: String
    ) throws {
        guard !haystack.contains(
            needle
        ) else {
            throw ScriptedProjectDiscoveryTestError.expectedMutation(
                message
            )
        }
    }

    static func assertOccurrenceCount(
        _ haystack: String,
        _ needle: String,
        expected: Int,
        _ message: String
    ) throws {
        let actual = haystack.components(
            separatedBy: needle
        ).count - 1

        guard actual == expected else {
            throw ScriptedProjectDiscoveryTestError.expectedMutation(
                "\(message). Expected \(expected), found \(actual)."
            )
        }
    }

    static func assertEqual(
        _ actual: String,
        _ expected: String,
        _ message: String
    ) throws {
        guard actual == expected else {
            throw ScriptedProjectDiscoveryTestError.expectedMutation(
                message
            )
        }
    }
}

enum ScriptedProjectDiscoveryTestError: Error, Sendable, LocalizedError {
    case expectedEnvReadAttempt
    case expectedEnvReadRejection
    case expectedApproval
    case expectedMutateApproval(String)
    case expectedCompletion
    case expectedMutation(String)

    var errorDescription: String? {
        switch self {
        case .expectedEnvReadAttempt:
            return "Expected scripted project discovery flow to attempt read_file on the hidden .env fixture, but no .env read result was observed."

        case .expectedEnvReadRejection:
            return "Expected hidden .env read_file access to be rejected by the sandbox, but it was not rejected."

        case .expectedApproval:
            return "Expected scripted project discovery flow to suspend for mutate_files approval, but it did not."

        case .expectedMutateApproval(let toolName):
            return "Expected approval for mutate_files, but the pending tool was '\(toolName)'."

        case .expectedCompletion:
            return "Expected scripted project discovery flow to complete after approval or denial."

        case .expectedMutation(let message):
            return message
        }
    }
}
