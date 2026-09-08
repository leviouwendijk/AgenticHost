import AgenticExecution
import AgenticHost
import AgenticIO
import AgenticModels
import AgenticRuntime
import AgenticWorkspace
import Agentic
import AgenticInterfaces
import Foundation
import TestFlows

enum ModeCommandInstantiationTestCase {
    static func makePrepare() -> AgenticInterfaceTestCase {
        .init(
            id: "mode-command-prepare",
            summary: "Instantiate a typed mode run command into a ModeRunPreparation."
        ) { _ in
            try await runPrepare()
        }
    }

    static func makeExecute() -> AgenticInterfaceTestCase {
        .init(
            id: "mode-command-execute",
            summary: "Execute a typed mode run command through the interface controller."
        ) { _ in
            try await runExecute()
        }
    }

    static func runPrepare() async throws {
        let fixture = try makeFixture()
        let factory = try AgenticRunCommandFactory.standard()
        let preparation = try factory.prepare(
            fixture.command,
            tools: fixture.tools,
            skills: fixture.skills
        )

        try checksPreparation(
            preparation,
            command: fixture.command
        )

        print(
            preparation.screen.renderedHeader()
        )

        print(
            "mode-command-prepare ok"
        )
    }

    static func runExecute() async throws {
        let fixture = try makeFixture()
        let recorder = CommandRecordingInterfaceEventSink()
        let presenter = TerminalAgenticRunPresenter(
            sinks: [
                recorder
            ],
            showsVerboseEvents: true
        )
        let controller = AgenticInterfaceRunController(
            presenter: presenter,
            approvalChooser: ScriptedApprovalChooser(
                choice: .approve
            )
        )
        let executor = try AgenticRunCommandExecutor(
            factory: .standard(),
            controller: controller
        )

        let execution = try await executor.execute(
            fixture.command,
            modelBroker: fixture.broker,
            tools: fixture.tools,
            skills: fixture.skills,
            sessionID: fixture.sessionID,
            workspace: fixture.workspace,
            historyStore: fixture.historyStore,
            resumeMetadata: [
                "summary": "mode command execution approved"
            ]
        )

        try checksPreparation(
            execution.preparation,
            command: fixture.command
        )

        try checksExecution(
            execution,
            fixture: fixture
        )

        try await checksRecordedEvents(
            recorder
        )

        print(
            "mode-command-execute ok"
        )
    }
}

private extension ModeCommandInstantiationTestCase {
    struct Fixture: Sendable {
        var sessionID: String
        var workspaceRoot: URL
        var workspace: AgentWorkspace
        var historyStore: FileHistoryStore
        var broker: AgentModelBroker
        var command: AgenticRunCommand
        var tools: ToolRegistry
        var skills: SkillRegistry
    }

    static func makeFixture() throws -> Fixture {
        let sessionID = "mode-command-\(UUID().uuidString)"
        let workspaceRoot = try AgenticInterfaceTestEnvironment.workspaceRoot()
        let workspace = try AgentWorkspace(
            root: workspaceRoot
        )

        try ScriptedMutateFilesFixture.reset(
            workspaceRoot: workspaceRoot
        )

        let tools = try Agentic.tool.registry(
            toolSets: [
                CoreToolSet()
            ]
        )

        let skills = try Agentic.skill.registry(
            skills: [
                AgentSkill(
                    identifier: "safe-file-editing",
                    name: "Safe file editing",
                    summary: "Read before writing.",
                    body: "Read before writing. Prefer targeted edits and report concrete changed paths."
                )
            ]
        )

        let command = AgenticRunCommand(
            modeID: .coder,
            prompt: "Patch the formatter through a typed command.",
            system: "Use the typed command context and request a bounded mutation.",
            baseConfiguration: .init(
                maximumIterations: 6,
                autonomyMode: .auto_observe,
                historyPersistenceMode: .checkpointmutation
            ),
            metadata: [
                "test_case": "mode-command-instantiation"
            ]
        )

        let historyStore = FileHistoryStore(
            sessionsdir: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agentic-interface-mode-command-\(UUID().uuidString)",
                    isDirectory: true
                )
        )

        return .init(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            workspace: workspace,
            historyStore: historyStore,
            broker: try scriptedBroker(),
            command: command,
            tools: tools,
            skills: skills
        )
    }

    static func scriptedBroker() throws -> AgentModelBroker {
        let adapterID: AgentModelAdapterIdentifier = "scripted_mode_command"
        let profileID: AgentModelProfileIdentifier = "scripted_mode_command:coder"

        return try AgentModelBroker(
            profiles: .init(
                profiles: [
                    AgentModelProfile(
                        identifier: profileID,
                        adapterIdentifier: adapterID,
                        model: "scripted-mode-command",
                        title: "Scripted Mode Command",
                        purposes: [
                            .coder
                        ],
                        capabilities: [
                            .text,
                            .reasoning,
                            .tool_use
                        ],
                        cost: .free,
                        latency: .low,
                        privacy: .local_private,
                        metadata: [
                            "test_case": "mode-command-instantiation"
                        ]
                    )
                ]
            ),
            adapters: .init(
                adapters: [
                    (
                        adapterID,
                        CommandScriptedModelAdapter()
                    )
                ]
            ),
            router: StaticAgentModelRouter(
                defaults: [
                    .coder: profileID
                ],
                defaultProfileIdentifier: profileID
            )
        )
    }

    static func checksPreparation(
        _ preparation: ModeRunPreparation,
        command: AgenticRunCommand
    ) throws {
        try Expect.equal(
            preparation.command.modeID,
            command.modeID,
            "command preparation preserves mode id"
        )

        try Expect.equal(
            preparation.command.prompt,
            command.prompt,
            "command preparation preserves prompt"
        )

        try Expect.equal(
            preparation.request.metadata["mode_id"],
            "coder",
            "command preparation includes mode metadata"
        )

        try Expect.equal(
            preparation.request.metadata["test_case"],
            "mode-command-instantiation",
            "command preparation preserves custom metadata"
        )

        try Expect.equal(
            preparation.request.tools.map(\.name).sorted(),
            [
                "mutate_files",
                "read_file",
                "scan_paths"
            ],
            "command preparation uses mode-filtered tools"
        )

        try Expect.true(
            preparation.request.messages.contains { message in
                message.role == .system
                    && message.content.text.contains("Skill ID: safe-file-editing")
            },
            "command preparation includes mode skill context"
        )
    }

    static func checksExecution(
        _ execution: AgenticRunCommandExecution,
        fixture: Fixture
    ) throws {
        try Expect.equal(
            execution.command,
            fixture.command,
            "command execution preserves command"
        )

        try Expect.equal(
            execution.result.isCompleted,
            true,
            "command execution completes"
        )

        try ScriptedMutateFilesFixture.assertApprovedMutation(
            workspaceRoot: fixture.workspaceRoot
        )

        let responseText = execution.result.finalResult?.response?.message.content.text ?? ""

        try Expect.true(
            responseText.contains("command mutate_files completed"),
            "command execution final response"
        )
    }

    static func checksRecordedEvents(
        _ recorder: CommandRecordingInterfaceEventSink
    ) async throws {
        let events = await recorder.snapshot()

        try Expect.true(
            events.containsModeRunStarted,
            "command execution records mode run start"
        )

        try Expect.true(
            events.containsToolPreflight,
            "command execution records tool preflight"
        )

        try Expect.true(
            events.containsApprovalDecision,
            "command execution records approval decision"
        )
    }
}

private struct CommandScriptedModelAdapter: AgentModelAdapter {
    var response: AgentModelResponseProviding {
        CommandScriptedModelResponseProvider()
    }
}

private struct CommandScriptedModelResponseProvider: AgentModelResponseProviding {
    func buffered(
        request: AgentRequest
    ) async throws -> AgentResponse {
        if let toolResult = latestToolResult(
            in: request
        ) {
            return .init(
                message: .init(
                    role: .assistant,
                    text: finalMessage(
                        from: toolResult
                    )
                ),
                stopReason: .end_turn,
                metadata: [
                    "scripted_model": "mode-command-instantiation"
                ]
            )
        }

        assertModeCommandRequest(
            request
        )

        let toolCall = AgentToolCall(
            id: "tool-call-mode-command",
            name: MutateFilesTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                ScriptedMutateFilesToolInput.valid
            )
        )

        return .init(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .tool_call(
                            toolCall
                        )
                    ]
                )
            ),
            stopReason: .tool_use,
            metadata: [
                "scripted_model": "mode-command-instantiation"
            ]
        )
    }

    func stream(
        request: AgentRequest
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await buffered(
                        request: request
                    )

                    continuation.yield(
                        .completed(
                            response
                        )
                    )

                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: error
                    )
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func latestToolResult(
        in request: AgentRequest
    ) -> AgentToolResult? {
        for message in request.messages.reversed() {
            for block in message.content.blocks.reversed() {
                guard case .tool_result(let result) = block else {
                    continue
                }

                return result
            }
        }

        return nil
    }

    private func assertModeCommandRequest(
        _ request: AgentRequest
    ) {
        precondition(
            request.metadata["mode_id"] == "coder",
            "Mode command expected request metadata mode_id=coder."
        )

        precondition(
            request.metadata["test_case"] == "mode-command-instantiation",
            "Mode command expected command metadata."
        )

        precondition(
            request.tools.map(\.name).sorted() == [
                "mutate_files",
                "read_file",
                "scan_paths"
            ],
            "Mode command expected coder mode filtered tools."
        )

        precondition(
            request.messages.contains { message in
                message.role == .system
                    && message.content.text.contains("Skill ID: safe-file-editing")
            },
            "Mode command expected safe-file-editing skill context."
        )
    }

    private func finalMessage(
        from toolResult: AgentToolResult
    ) -> String {
        if toolResult.isError {
            return "command mutate_files denied or failed."
        }

        return "command mutate_files completed through typed command execution."
    }
}

private actor CommandRecordingInterfaceEventSink: AgenticInterfaceEventSink {
    private var events: [AgenticInterfaceEvent] = []

    func record(
        _ event: AgenticInterfaceEvent
    ) async throws {
        events.append(
            event
        )
    }

    func snapshot() -> [AgenticInterfaceEvent] {
        events
    }
}

private extension Array where Element == AgenticInterfaceEvent {
    var containsModeRunStarted: Bool {
        contains { event in
            if case .modeRunStarted = event {
                return true
            }

            return false
        }
    }

    var containsToolPreflight: Bool {
        contains { event in
            if case .toolPreflight = event {
                return true
            }

            return false
        }
    }

    var containsApprovalDecision: Bool {
        contains { event in
            if case .approvalDecision = event {
                return true
            }

            return false
        }
    }
}
