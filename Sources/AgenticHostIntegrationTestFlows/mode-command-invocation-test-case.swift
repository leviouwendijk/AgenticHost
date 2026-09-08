import AgenticExecution
import AgenticIO
import AgenticModels
import AgenticRuntime
import AgenticCommandLine
import AgenticHost
import AgenticWorkspace
import Agentic
import AgenticInterfaces
import Foundation
import TestFlows

enum ModeCommandInvocationTestCase {
    static func makeParsesAndPrepares() -> AgenticInterfaceTestCase {
        .init(
            id: "run-command-invocation-parses-and-prepares",
            summary: "Parse argv through the invocation executor and prepare a mode run."
        ) { _ in
            try await runParsesAndPrepares()
        }
    }

    static func makeExecutesApprovedCoderCommand() -> AgenticInterfaceTestCase {
        .init(
            id: "run-command-invocation-executes-approved-coder-command",
            summary: "Execute argv through parser, command executor, controller, approval, and resume."
        ) { _ in
            try await runExecutesApprovedCoderCommand()
        }
    }

    static func makePreservesArgvMetadata() -> AgenticInterfaceTestCase {
        .init(
            id: "run-command-invocation-preserves-argv-metadata",
            summary: "Preserve argv metadata through invocation preparation."
        ) { _ in
            try await runPreservesArgvMetadata()
        }
    }

    static func makeRejectsUnknownModeBeforeExecution() -> AgenticInterfaceTestCase {
        .init(
            id: "run-command-invocation-rejects-unknown-mode-before-execution",
            summary: "Reject unknown mode before creating a runner or presenting run events."
        ) { _ in
            try await runRejectsUnknownModeBeforeExecution()
        }
    }

    static func runParsesAndPrepares() async throws {
        let fixture = try makeFixture()
        let executor = try invocationExecutor(
            recorder: nil
        )

        let prepared = try executor.prepare(
            fixture.argv,
            tools: fixture.tools,
            skills: fixture.skills,
            baseConfiguration: fixture.baseConfiguration,
            additionalMetadata: fixture.hostMetadata
        )

        try checksPrepared(
            prepared,
            fixture: fixture
        )

        print(
            prepared.preparation.screen.renderedHeader()
        )

        print(
            "run-command-invocation-parses-and-prepares ok"
        )
    }

    static func runExecutesApprovedCoderCommand() async throws {
        let fixture = try makeFixture()
        let recorder = InvocationRecordingInterfaceEventSink()
        let executor = try invocationExecutor(
            recorder: recorder
        )

        let result = try await executor.execute(
            fixture.argv,
            modelBroker: fixture.broker,
            tools: fixture.tools,
            skills: fixture.skills,
            sessionID: fixture.sessionID,
            workspace: fixture.workspace,
            historyStore: fixture.historyStore,
            baseConfiguration: fixture.baseConfiguration,
            additionalMetadata: fixture.hostMetadata,
            resumeMetadata: [
                "summary": "run command invocation approved"
            ]
        )

        try checksInvocationResult(
            result,
            fixture: fixture
        )

        try await checksRecordedExecutionEvents(
            recorder
        )

        print(
            "run-command-invocation-executes-approved-coder-command ok"
        )
    }

    static func runPreservesArgvMetadata() async throws {
        let fixture = try makeFixture()
        let executor = try invocationExecutor(
            recorder: nil
        )

        let prepared = try executor.prepare(
            fixture.argv,
            tools: fixture.tools,
            skills: fixture.skills,
            baseConfiguration: fixture.baseConfiguration,
            additionalMetadata: fixture.hostMetadata
        )

        try Expect.equal(
            prepared.invocation.command.metadata["source"],
            "aginttest",
            "invocation preserves argv source metadata"
        )

        try Expect.equal(
            prepared.invocation.command.metadata["test_case"],
            "run-command-invocation",
            "invocation preserves argv test_case metadata"
        )

        try Expect.equal(
            prepared.invocation.command.metadata["host"],
            "interface-test",
            "invocation applies host metadata"
        )

        try Expect.equal(
            prepared.preparation.request.metadata["source"],
            "aginttest",
            "prepared request preserves argv source metadata"
        )

        print(
            "metadata \(prepared.invocation.command.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))"
        )

        print(
            "run-command-invocation-preserves-argv-metadata ok"
        )
    }

    static func runRejectsUnknownModeBeforeExecution() async throws {
        let fixture = try makeFixture()
        let recorder = InvocationRecordingInterfaceEventSink()
        let executor = try invocationExecutor(
            recorder: recorder
        )

        do {
            _ = try await executor.execute(
                [
                    "--mode",
                    "does_not_exist",
                    "Patch the formatter."
                ],
                modelBroker: fixture.broker,
                tools: fixture.tools,
                skills: fixture.skills,
                sessionID: fixture.sessionID,
                workspace: fixture.workspace,
                historyStore: fixture.historyStore,
                baseConfiguration: fixture.baseConfiguration
            )

            throw ModeCommandInvocationTestError.expectedUnknownMode
        } catch AgenticRunCommandArgumentParserError.unknownMode(let mode, _) {
            try Expect.equal(
                mode,
                "does_not_exist",
                "invocation rejected unknown mode"
            )
        }

        let events = await recorder.snapshot()

        try Expect.equal(
            events.isEmpty,
            true,
            "unknown mode rejected before presentation"
        )

        print(
            "unknown mode rejected before execution"
        )

        print(
            "run-command-invocation-rejects-unknown-mode-before-execution ok"
        )
    }
}

private extension ModeCommandInvocationTestCase {
    struct Fixture: Sendable {
        var sessionID: String
        var workspaceRoot: URL
        var workspace: AgentWorkspace
        var historyStore: FileHistoryStore
        var broker: AgentModelBroker
        var tools: ToolRegistry
        var skills: SkillRegistry
        var argv: [String]
        var hostMetadata: [String: String]
        var baseConfiguration: AgentRunnerConfiguration
    }

    static func makeFixture() throws -> Fixture {
        let sessionID = "run-command-invocation-\(UUID().uuidString)"
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

        let historyStore = FileHistoryStore(
            sessionsdir: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agentic-interface-run-command-invocation-\(UUID().uuidString)",
                    isDirectory: true
                )
        )

        return .init(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            workspace: workspace,
            historyStore: historyStore,
            broker: try scriptedBroker(),
            tools: tools,
            skills: skills,
            argv: [
                "agentic",
                "run",
                "--mode",
                "coder",
                "--system",
                "Use the typed argv invocation context and request a bounded mutation.",
                "--metadata",
                "source=aginttest",
                "--metadata",
                "test_case=run-command-invocation",
                "Patch the formatter through argv invocation."
            ],
            hostMetadata: [
                "host": "interface-test"
            ],
            baseConfiguration: .init(
                maximumIterations: 6,
                autonomyMode: .auto_observe,
                historyPersistenceMode: .checkpointmutation
            )
        )
    }

    static func scriptedBroker() throws -> AgentModelBroker {
        let adapterID: AgentModelAdapterIdentifier = "scripted_run_command_invocation"
        let profileID: AgentModelProfileIdentifier = "scripted_run_command_invocation:coder"

        return try AgentModelBroker(
            profiles: .init(
                profiles: [
                    AgentModelProfile(
                        identifier: profileID,
                        adapterIdentifier: adapterID,
                        model: "scripted-run-command-invocation",
                        title: "Scripted Run Command Invocation",
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
                            "test_case": "run-command-invocation"
                        ]
                    )
                ]
            ),
            adapters: .init(
                adapters: [
                    (
                        adapterID,
                        InvocationScriptedModelAdapter()
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

    static func invocationExecutor(
        recorder: InvocationRecordingInterfaceEventSink?
    ) throws -> AgenticRunCommandInvocationExecutor {
        let presenter = TerminalAgenticRunPresenter(
            sinks: recorder.map {
                [
                    $0
                ]
            } ?? [],
            showsVerboseEvents: true
        )
        let controller = AgenticInterfaceRunController(
            presenter: presenter,
            approvalChooser: ScriptedApprovalChooser(
                choice: .approve
            )
        )

        return try .standard(
            controller: controller
        )
    }

    static func checksPrepared(
        _ prepared: AgenticRunCommandInvocationExecutor.Preparation,
        fixture: Fixture
    ) throws {
        try Expect.equal(
            prepared.invocation.arguments.modeID,
            .coder,
            "invocation parsed mode"
        )

        try Expect.equal(
            prepared.invocation.command.prompt,
            "Patch the formatter through argv invocation.",
            "invocation parsed prompt"
        )

        try Expect.equal(
            prepared.invocation.command.system,
            "Use the typed argv invocation context and request a bounded mutation.",
            "invocation parsed system"
        )

        try Expect.equal(
            prepared.preparation.request.metadata["mode_id"],
            "coder",
            "invocation preparation includes mode metadata"
        )

        try Expect.equal(
            prepared.preparation.request.metadata["source"],
            "aginttest",
            "invocation preparation includes argv metadata"
        )

        try Expect.equal(
            prepared.preparation.request.metadata["host"],
            "interface-test",
            "invocation preparation includes host metadata"
        )

        try Expect.equal(
            prepared.preparation.request.tools.map(\.name).sorted(),
            [
                "mutate_files",
                "read_file",
                "scan_paths"
            ],
            "invocation preparation uses mode-filtered tools"
        )

        try Expect.true(
            prepared.preparation.request.messages.contains { message in
                message.role == .system
                    && message.content.text.contains("Skill ID: safe-file-editing")
            },
            "invocation preparation includes loaded skill context"
        )
    }

    static func checksInvocationResult(
        _ result: AgenticRunCommandInvocationResult,
        fixture: Fixture
    ) throws {
        try Expect.equal(
            result.invocation.command.modeID,
            .coder,
            "invocation result command mode"
        )

        try Expect.equal(
            result.execution.command.metadata["test_case"],
            "run-command-invocation",
            "invocation execution preserves argv metadata"
        )

        try Expect.equal(
            result.execution.command.metadata["host"],
            "interface-test",
            "invocation execution preserves host metadata"
        )

        try Expect.equal(
            result.result.isCompleted,
            true,
            "invocation execution completes"
        )

        try ScriptedMutateFilesFixture.assertApprovedMutation(
            workspaceRoot: fixture.workspaceRoot
        )

        let responseText = result.result.finalResult?.response?.message.content.text ?? ""

        try Expect.true(
            responseText.contains("invocation mutate_files completed"),
            "invocation final response"
        )
    }

    static func checksRecordedExecutionEvents(
        _ recorder: InvocationRecordingInterfaceEventSink
    ) async throws {
        let events = await recorder.snapshot()

        try Expect.true(
            events.containsModeRunStarted,
            "invocation records mode run start"
        )

        try Expect.true(
            events.containsToolPreflight,
            "invocation records tool preflight"
        )

        try Expect.true(
            events.containsApprovalDecision,
            "invocation records approval decision"
        )
    }
}

private struct InvocationScriptedModelAdapter: AgentModelAdapter {
    var response: AgentModelResponseProviding {
        InvocationScriptedModelResponseProvider()
    }
}

private struct InvocationScriptedModelResponseProvider: AgentModelResponseProviding {
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
                    "scripted_model": "run-command-invocation"
                ]
            )
        }

        assertInvocationRequest(
            request
        )

        let toolCall = AgentToolCall(
            id: "tool-call-run-command-invocation",
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
                "scripted_model": "run-command-invocation"
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

    private func assertInvocationRequest(
        _ request: AgentRequest
    ) {
        precondition(
            request.metadata["mode_id"] == "coder",
            "Run command invocation expected request metadata mode_id=coder."
        )

        precondition(
            request.metadata["source"] == "aginttest",
            "Run command invocation expected argv metadata source=aginttest."
        )

        precondition(
            request.metadata["test_case"] == "run-command-invocation",
            "Run command invocation expected argv metadata test_case=run-command-invocation."
        )

        precondition(
            request.metadata["host"] == "interface-test",
            "Run command invocation expected host metadata."
        )

        precondition(
            request.tools.map(\.name).sorted() == [
                "mutate_files",
                "read_file",
                "scan_paths"
            ],
            "Run command invocation expected coder mode filtered tools."
        )

        precondition(
            request.messages.contains { message in
                message.role == .system
                    && message.content.text.contains("Skill ID: safe-file-editing")
            },
            "Run command invocation expected safe-file-editing skill context."
        )
    }

    private func finalMessage(
        from toolResult: AgentToolResult
    ) -> String {
        if toolResult.isError {
            return "invocation mutate_files denied or failed."
        }

        return "invocation mutate_files completed through argv command execution."
    }
}

private actor InvocationRecordingInterfaceEventSink: AgenticInterfaceEventSink {
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

private enum ModeCommandInvocationTestError: Error, Sendable, LocalizedError {
    case expectedUnknownMode

    var errorDescription: String? {
        switch self {
        case .expectedUnknownMode:
            return "Expected unknown mode rejection before execution."
        }
    }
}
