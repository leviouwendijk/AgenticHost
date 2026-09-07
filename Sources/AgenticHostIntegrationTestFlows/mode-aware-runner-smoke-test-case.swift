import AgenticIO
import AgenticHost
import AgenticModels
import AgenticRuntime
import AgenticWorkspace
import Agentic
import AgenticInterfaces
import Foundation
import TestFlows

enum ModeAwareRunnerSmokeTestCase {
    static func make() -> AgenticInterfaceTestCase {
        .init(
            id: "mode-aware-runner-smoke",
            summary: "Run a scripted model through a mode-built AgentRunner and resume after approval."
        ) { _ in
            try await run()
        }
    }

    static func run() async throws {
        let fixture = try makeFixture()
        let recorder = ModeRunnerRecordingInterfaceEventSink()
        let presenter = TerminalAgenticRunPresenter(
            sinks: [
                recorder
            ],
            showsVerboseEvents: true
        )

        try await presenter.present(
            .modeRunStarted(
                fixture.preparation.command
            )
        )

        try checksPreparedRequest(
            fixture
        )

        let runner = fixture.preparation.runner(
            modelBroker: fixture.broker,
            workspace: fixture.workspace,
            historyStore: fixture.historyStore
        )

        let initialResult = try await runner.run(
            fixture.preparation.request,
            sessionID: fixture.sessionID
        )

        guard let pendingApproval = initialResult.pendingApproval else {
            try await presenter.present(
                initialResult
            )

            throw TestFlowAssertionFailure(
                label: "mode-aware runner reaches pending approval",
                message: "Expected mode-aware runner smoke test to suspend for approval."
            )
        }

        try checksPendingApproval(
            fixture,
            pendingApproval: pendingApproval
        )

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

        try await presenter.present(
            .approvalDecision(
                .approved
            )
        )

        let resumed = try await runner.resume(
            sessionID: initialResult.sessionID,
            approvalDecision: .approved,
            metadata: [
                "summary": "mode-aware scripted approval"
            ]
        )

        try await presenter.present(
            resumed
        )

        try checksResumedResult(
            fixture,
            resumed: resumed
        )

        try await checksRecordedEvents(
            recorder
        )

        print(
            "mode-aware-runner-smoke ok"
        )
    }
}

private extension ModeAwareRunnerSmokeTestCase {
    struct Fixture: Sendable {
        var sessionID: String
        var workspaceRoot: URL
        var workspace: AgentWorkspace
        var historyStore: FileHistoryStore
        var broker: AgentModelBroker
        var preparation: ModeRunPreparation
    }

    static func makeFixture() throws -> Fixture {
        let sessionID = "mode-aware-runner-smoke-\(UUID().uuidString)"
        let workspaceRoot = try AgenticInterfaceTestEnvironment.workspaceRoot()
        let workspace = try AgentWorkspace(
            root: workspaceRoot
        )

        try ScriptedMutateFilesFixture.reset(
            workspaceRoot: workspaceRoot
        )

        let sourceTools = try Agentic.tool.registry(
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

        let preparation = try ModeRunFactory
            .standard()
            .make(
                modeID: .coder,
                prompt: "Patch the formatter through the mode-aware runner smoke test.",
                system: "Use the available mode context and request a bounded file mutation.",
                tools: sourceTools,
                skills: skills,
                baseConfiguration: .init(
                    maximumIterations: 6,
                    autonomyMode: .auto_observe,
                    historyPersistenceMode: .checkpointmutation
                ),
                metadata: [
                    "test_case": "mode-aware-runner-smoke"
                ]
            )

        let historyStore = FileHistoryStore(
            sessionsdir: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agentic-interface-mode-aware-runner-smoke-\(UUID().uuidString)",
                    isDirectory: true
                )
        )

        return .init(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            workspace: workspace,
            historyStore: historyStore,
            broker: try scriptedBroker(),
            preparation: preparation
        )
    }

    static func scriptedBroker() throws -> AgentModelBroker {
        let adapterID: AgentModelAdapterIdentifier = "scripted_mode_runner"
        let profileID: AgentModelProfileIdentifier = "scripted_mode_runner:coder"

        return try AgentModelBroker(
            profiles: .init(
                profiles: [
                    AgentModelProfile(
                        identifier: profileID,
                        adapterIdentifier: adapterID,
                        model: "scripted-mode-runner",
                        title: "Scripted Mode Runner",
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
                            "test_case": "mode-aware-runner-smoke"
                        ]
                    )
                ]
            ),
            adapters: .init(
                adapters: [
                    (
                        adapterID,
                        ScriptedModeRunModelAdapter()
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

    static func checksPreparedRequest(
        _ fixture: Fixture
    ) throws {
        let request = fixture.preparation.request

        try Expect.equal(
            request.metadata["mode_id"],
            "coder",
            "mode runner request includes mode id"
        )

        try Expect.equal(
            request.tools.map(\.name).sorted(),
            [
                "mutate_files",
                "read_file",
                "scan_paths"
            ],
            "mode runner request uses filtered coder tools"
        )

        try Expect.true(
            request.messages.contains { message in
                message.role == .system
                    && message.content.text.contains("Skill ID: safe-file-editing")
            },
            "mode runner request includes loaded skill context"
        )
    }

    static func checksPendingApproval(
        _ fixture: Fixture,
        pendingApproval: PendingApproval
    ) throws {
        let exposedTools = Set(
            fixture.preparation.request.tools.map(\.name)
        )

        try Expect.equal(
            pendingApproval.toolCall.name,
            MutateFilesTool.identifier.rawValue,
            "mode runner pending approval tool"
        )

        try Expect.true(
            exposedTools.contains(
                pendingApproval.toolCall.name
            ),
            "pending approval tool is mode exposed"
        )

        try Expect.equal(
            pendingApproval.preflight.toolName,
            MutateFilesTool.identifier.rawValue,
            "mode runner pending approval preflight tool"
        )
    }

    static func checksResumedResult(
        _ fixture: Fixture,
        resumed: AgentRunResult
    ) throws {
        try Expect.equal(
            resumed.isCompleted,
            true,
            "mode runner resumes to completion"
        )

        try ScriptedMutateFilesFixture.assertApprovedMutation(
            workspaceRoot: fixture.workspaceRoot
        )

        let responseText = resumed.response?.message.content.text ?? ""

        try Expect.true(
            responseText.contains("mode-aware mutate_files completed"),
            "mode runner final scripted response"
        )
    }

    static func checksRecordedEvents(
        _ recorder: ModeRunnerRecordingInterfaceEventSink
    ) async throws {
        let events = await recorder.snapshot()

        try Expect.true(
            events.containsModeRunStarted,
            "interface recorded mode run start"
        )

        try Expect.true(
            events.containsToolPreflight,
            "interface recorded tool preflight"
        )

        try Expect.true(
            events.containsApprovalDecision,
            "interface recorded approval decision"
        )

        // try Expect.true(
        //     events.containsRunCompleted,
        //     "interface recorded run completed"
        // )
    }
}

private struct ScriptedModeRunModelAdapter: AgentModelAdapter {
    var response: AgentModelResponseProviding {
        ScriptedModeRunModelResponseProvider()
    }
}

private struct ScriptedModeRunModelResponseProvider: AgentModelResponseProviding {
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
                    "scripted_model": "mode-aware-runner-smoke"
                ]
            )
        }

        assertModeRequest(
            request
        )

        let toolCall = AgentToolCall(
            id: "tool-call-mode-aware-runner-smoke",
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
                "scripted_model": "mode-aware-runner-smoke"
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

    private func assertModeRequest(
        _ request: AgentRequest
    ) {
        precondition(
            request.metadata["mode_id"] == "coder",
            "Mode-aware runner smoke test expected request metadata mode_id=coder."
        )

        precondition(
            request.tools.map(\.name).sorted() == [
                "mutate_files",
                "read_file",
                "scan_paths"
            ],
            "Mode-aware runner smoke test expected coder mode filtered tools."
        )

        precondition(
            request.messages.contains { message in
                message.role == .system
                    && message.content.text.contains("Skill ID: safe-file-editing")
            },
            "Mode-aware runner smoke test expected safe-file-editing skill context."
        )
    }

    private func finalMessage(
        from toolResult: AgentToolResult
    ) -> String {
        if toolResult.isError {
            return "mode-aware mutate_files failed."
        }

        return "mode-aware mutate_files completed through scripted approval."
    }
}

private actor ModeRunnerRecordingInterfaceEventSink: AgenticInterfaceEventSink {
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
