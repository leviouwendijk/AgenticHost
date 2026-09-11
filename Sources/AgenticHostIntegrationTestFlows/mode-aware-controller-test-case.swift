import AgenticIO
import AgenticHost
import AgenticModels
import AgenticRuntime
import AgenticWorkspace
import Agentic
import AgenticInterfaces
import Foundation
import TestFlows

struct ScriptedApprovalChooser:
    AgenticApprovalChoosing
{
    let choice: AgenticApprovalChoice

    func choose(
        _ prompt: AgenticApprovalPrompt
    ) async throws -> AgenticApprovalChoice {
        _ = prompt
        return choice
    }
}

enum ModeAwareControllerTestCase {
    static func makeApprove() -> AgenticInterfaceTestCase {
        .init(
            id: "mode-aware-controller-approve",
            summary: "Run a mode preparation through AgenticInterfaceRunController and approve the pending mutation."
        ) { _ in
            try await run(
                choice: .approve
            )
        }
    }

    static func makeDeny() -> AgenticInterfaceTestCase {
        .init(
            id: "mode-aware-controller-deny",
            summary: "Run a mode preparation through AgenticInterfaceRunController and deny the pending mutation."
        ) { _ in
            try await run(
                choice: .deny
            )
        }
    }

    static func makeSkip() -> AgenticInterfaceTestCase {
        .init(
            id: "mode-aware-controller-skip",
            summary: "Run a mode preparation through AgenticInterfaceRunController and explicitly skip the pending mutation."
        ) { _ in
            try await run(
                choice: .skip
            )
        }
    }

    static func makeStop() -> AgenticInterfaceTestCase {
        .init(
            id: "mode-aware-controller-stop",
            summary: "Run a mode preparation through AgenticInterfaceRunController and stop at pending approval."
        ) { _ in
            try await run(
                choice: .stop_run
            )
        }
    }

    static func run(
        choice: AgenticApprovalChoice
    ) async throws {
        let fixture = try makeFixture()
        let recorder = ControllerRecordingInterfaceEventSink()
        let presenter = TerminalAgenticRunPresenter(
            sinks: [
                recorder
            ],
            showsVerboseEvents: true
        )
        let controller = AgenticInterfaceRunController(
            presenter: presenter,
            approvalChooser: ScriptedApprovalChooser(
                choice: choice
            )
        )

        let result = try await controller.run(
            fixture.preparation,
            model: .init(
                invoker: fixture.broker
            ),
            sessionID: fixture.sessionID,
            tooling: .init(
                workspace: fixture.workspace
            ),
            recording: .init(
                historyStore: fixture.historyStore
            ),
            resumeMetadata: [
                "summary": "mode-aware controller scripted decision"
            ]
        )

        try checksModeFilteredTools(
            fixture
        )

        try checksPendingApproval(
            fixture,
            result: result
        )

        switch choice {
        case .approve:
            try checksApprovedResult(
                fixture,
                result: result
            )

        case .deny:
            try checksDeniedResult(
                fixture,
                result: result
            )

        case .skip:
            try checksSkippedResult(
                fixture,
                result: result
            )

        case .stop_run:
            try checksStoppedResult(
                fixture,
                result: result,
                reason: "User stopped the run from the approval picker."
            )

        case .inspect_details,
             .show_diff:
            preconditionFailure(
                "Non-terminal approval choice escaped scripted controller test."
            )
        }

        try await checksRecordedEvents(
            recorder,
            choice: choice
        )

        print(
            "mode-aware-controller ok"
        )
    }
}

private extension ModeAwareControllerTestCase {
    struct Fixture: Sendable {
        var sessionID: String
        var workspaceRoot: URL
        var workspace: AgentWorkspace
        var originalSnapshot: ScriptedMutateFilesSnapshot
        var historyStore: FileHistoryStore
        var broker: AgentModelBroker
        var preparation: ModeRunPreparation
    }

    static func makeFixture() throws -> Fixture {
        let sessionID = "mode-aware-controller-\(UUID().uuidString)"
        let workspaceRoot = try AgenticInterfaceTestEnvironment.workspaceRoot()
        let workspace = try AgentWorkspace(
            root: workspaceRoot
        )

        try ScriptedMutateFilesFixture.reset(
            workspaceRoot: workspaceRoot
        )

        let originalSnapshot = try ScriptedMutateFilesFixture.snapshot(
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
                prompt: "Patch the formatter through the mode-aware interface controller.",
                system: "Use the available mode context and request a bounded file mutation.",
                tools: sourceTools,
                skills: skills,
                baseConfiguration: .init(
                    maximumIterations: 6,
                    autonomyMode: .auto_observe,
                    historyPersistenceMode: .checkpointmutation
                ),
                metadata: [
                    "test_case": "mode-aware-controller"
                ]
            )

        let historyStore = FileHistoryStore(
            sessionsdir: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agentic-interface-mode-aware-controller-\(UUID().uuidString)",
                    isDirectory: true
                )
        )

        return .init(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            workspace: workspace,
            originalSnapshot: originalSnapshot,
            historyStore: historyStore,
            broker: try scriptedBroker(),
            preparation: preparation
        )
    }

    static func scriptedBroker() throws -> AgentModelBroker {
        let gatewayID: AgentModelGatewayIdentifier = "scripted_interface_controller"
        let profileID: AgentModelProfileIdentifier = "scripted_interface_controller:coder"

        return try AgentModelBroker(
            profiles: .init(
                profiles: [
                    AgentModelProfile(
                        identifier: profileID,
                        gatewayIdentifier: gatewayID,
                        model: "scripted-interface-controller",
                        title: "Scripted Interface Controller",
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
                            "test_case": "mode-aware-controller"
                        ]
                    )
                ]
            ),
            gateways: .init(
                gateways: [
                    ControllerScriptedModelGateway()
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

    static func checksModeFilteredTools(
        _ fixture: Fixture
    ) throws {
        try Expect.equal(
            fixture.preparation.request.tools.map(\.name).sorted(),
            [
                "mutate_files",
                "read_file",
                "scan_paths"
            ],
            "controller preserves mode-filtered tools"
        )

        try Expect.equal(
            fixture.preparation.request.metadata["mode_id"],
            "coder",
            "controller preserves mode request metadata"
        )
    }

    static func checksPendingApproval(
        _ fixture: Fixture,
        result: AgenticInterfaceRunControllerResult
    ) throws {
        guard let pendingApproval = result.pendingApproval else {
            throw TestFlowAssertionFailure(
                label: "controller pending approval",
                message: "Expected controller to observe pending approval."
            )
        }

        let exposedTools = Set(
            fixture.preparation.request.tools.map(\.name)
        )

        try Expect.equal(
            pendingApproval.toolCall.name,
            MutateFilesTool.identifier.rawValue,
            "controller pending approval tool"
        )

        try Expect.true(
            exposedTools.contains(
                pendingApproval.toolCall.name
            ),
            "controller pending approval tool is mode-exposed"
        )
    }

    static func checksApprovedResult(
        _ fixture: Fixture,
        result: AgenticInterfaceRunControllerResult
    ) throws {
        try Expect.equal(
            result.isCompleted,
            true,
            "controller approved run completes"
        )

        try ScriptedMutateFilesFixture.assertApprovedMutation(
            workspaceRoot: fixture.workspaceRoot
        )

        let responseText = result.finalResult?.response?.message.content.text ?? ""

        try Expect.true(
            responseText.contains("controller mutate_files completed"),
            "controller approved final response"
        )
    }

    static func checksDeniedResult(
        _ fixture: Fixture,
        result: AgenticInterfaceRunControllerResult
    ) throws {
        try Expect.equal(
            result.isCompleted,
            true,
            "controller denied run completes"
        )

        try ScriptedMutateFilesFixture.assertUnchanged(
            workspaceRoot: fixture.workspaceRoot,
            originalSnapshot: fixture.originalSnapshot
        )

        let responseText = result.finalResult?.response?.message.content.text ?? ""

        try Expect.true(
            responseText.contains("controller mutate_files denied or failed"),
            "controller denied final response"
        )
    }

    static func checksSkippedResult(
        _ fixture: Fixture,
        result: AgenticInterfaceRunControllerResult
    ) throws {
        try Expect.equal(
            result.isCompleted,
            true,
            "controller skipped run completes"
        )

        try ScriptedMutateFilesFixture.assertUnchanged(
            workspaceRoot: fixture.workspaceRoot,
            originalSnapshot: fixture.originalSnapshot
        )

        let responseText = result.finalResult?.response?.message.content.text ?? ""

        try Expect.true(
            responseText.contains("controller mutate_files skipped"),
            "controller skipped final response"
        )
    }

    static func checksStoppedResult(
        _ fixture: Fixture,
        result: AgenticInterfaceRunControllerResult,
        reason: String
    ) throws {
        try Expect.equal(
            result.isStopped,
            true,
            "controller stopped result"
        )

        try Expect.equal(
            result.stoppedReason,
            reason,
            "controller stopped reason"
        )

        try Expect.equal(
            result.finalResult == nil,
            true,
            "controller stop does not resume runner"
        )

        try ScriptedMutateFilesFixture.assertUnchanged(
            workspaceRoot: fixture.workspaceRoot,
            originalSnapshot: fixture.originalSnapshot
        )
    }

    static func checksRecordedEvents(
        _ recorder: ControllerRecordingInterfaceEventSink,
        choice: AgenticApprovalChoice
    ) async throws {
        let events = await recorder.snapshot()

        try Expect.true(
            events.containsModeRunStarted,
            "controller records mode run start"
        )

        try Expect.true(
            events.containsToolPreflight,
            "controller records tool preflight"
        )

        switch choice {
        case .approve,
             .deny,
             .skip:
            try Expect.true(
                events.containsApprovalDecision,
                "controller records approval decision"
            )

            try Expect.true(
                !events.containsRunStopped,
                "controller does not record stop for approval decision"
            )

        case .stop_run,
             .inspect_details,
             .show_diff:
            try Expect.true(
                events.containsRunStopped,
                "controller records stopped run"
            )

            try Expect.true(
                !events.containsApprovalDecision,
                "controller does not record approval decision when stopped"
            )
        }
    }
}

private struct ControllerScriptedModelGateway: AgentModelGateway {
    let identifier: AgentModelGatewayIdentifier = "scripted_interface_controller"

    var response: AgentModelResponseProviding {
        ControllerScriptedModelResponseProvider()
    }
}

private struct ControllerScriptedModelResponseProvider: AgentModelResponseProviding {
    func buffered(
        request: AgentRequest,
        route _: AgentModelRoute,
        context _: AgentModelInvocationContext
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
                    "scripted_model": "mode-aware-controller"
                ]
            )
        }

        assertModeRequest(
            request
        )

        let toolCall = AgentToolCall(
            id: "tool-call-mode-aware-controller",
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
                "scripted_model": "mode-aware-controller"
            ]
        )
    }

    func stream(
        request: AgentRequest,
        route: AgentModelRoute,
        context: AgentModelInvocationContext
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await buffered(
                        request: request,
                        route: route,
                        context: context
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
            "Mode-aware controller expected request metadata mode_id=coder."
        )

        precondition(
            request.tools.map(\.name).sorted() == [
                "mutate_files",
                "read_file",
                "scan_paths"
            ],
            "Mode-aware controller expected coder mode filtered tools."
        )

        precondition(
            request.messages.contains { message in
                message.role == .system
                    && message.content.text.contains("Skill ID: safe-file-editing")
            },
            "Mode-aware controller expected safe-file-editing skill context."
        )
    }

    private func finalMessage(
        from toolResult: AgentToolResult
    ) -> String {
        if toolResult.isError {
            return "controller mutate_files denied or failed."
        }

        if encodedOutputText(
            from: toolResult
        ).contains("\"kind\":\"tool_skipped\"") {
            return "controller mutate_files skipped."
        }

        return "controller mutate_files completed through scripted approval."
    }

    private func encodedOutputText(
        from toolResult: AgentToolResult
    ) -> String {
        do {
            let data = try JSONEncoder().encode(
                toolResult.output
            )

            return String(
                decoding: data,
                as: UTF8.self
            )
        } catch {
            return String(
                describing: toolResult.output
            )
        }
    }
}

private actor ControllerRecordingInterfaceEventSink: AgenticInterfaceEventSink {
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

    var containsRunStopped: Bool {
        contains { event in
            if case .runStopped = event {
                return true
            }

            return false
        }
    }
}
