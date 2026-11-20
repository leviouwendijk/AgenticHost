import Agentic
@_spi(Testing) import AgenticHost
import AgenticRuntime
import AgenticSessions
import AgenticStandard
import Foundation
import IO
import Primitives
import TestFlows

extension AgentHostLocalFlowTesting {
    /// The conversation's tool definitions stay as its first run declared
    /// them: inspection adds nothing, a new selection waits as pending
    /// until `:declare` (or a lost cache), and a withdrawn capability is
    /// announced in the history while its definition stays.
    static func runConversationDefinitions() async throws -> [TestDiagnostic] {
        let echo = GatewayFlowEchoTool.identifier
        let inspect = FunctionCall(
            id: "definitions-inspect",
            name: Standard.Tools.InspectCapability.identifier.rawValue,
            input: .object([
                "arguments": try JSONValue.encoding(
                    Standard.Tools.InspectCapability.Input(kind: .tool, identifier: echo.rawValue)
                ),
            ])
        )
        let gateway = GatewayFlowScriptedModelGateway(bufferedResponses: [
            .init(message: .init(role: .assistant, content: .init(blocks: [.call(inspect)])), stopReason: .tool_use),
            .init(message: .init(role: .assistant, text: "inspected"), stopReason: .end_turn),
            .init(message: .init(role: .assistant, text: "second turn"), stopReason: .end_turn),
            .init(message: .init(role: .assistant, text: "third turn"), stopReason: .end_turn),
            .init(message: .init(role: .assistant, text: "fourth turn"), stopReason: .end_turn),
        ])
        let application = Agentic.application("host-definitions-fixture") {
            tools {
                GatewayFlowEchoTool()
            }
            install(Standard.self)
            modelProvider(AgentHostLocalModelProvider(modelGateway: gateway))
        }
        let host = AgentHost.Local(runtime: try await AgenticRuntime(application: application))
        let session: AgentHost.Session.ID = "conversation-definitions"
        _ = try await host.start(.init(id: session))

        let everything = AgentCapabilitySet(tools: [echo] + Standard.Tools.discovery)
        func turn(
            _ prompt: String,
            available: AgentCapabilitySet = everything,
            visible: AgentCapabilitySet
        ) async throws -> AgentExecutor.Result {
            let result = try await host.submit(.init(
                session: session,
                prompt: prompt,
                execution: .init(
                    availableCapabilities: available,
                    visibleCapabilities: visible,
                    configuration: .init(runLimits: .init(iterations: 3))
                )
            ))
            try Expect.true(result.isCompleted, "\(prompt) completes: \(result.phase) \(String(describing: result.failure))")
            return result
        }
        func pending(_ result: AgentExecutor.Result) -> Run.Event.Advertisement.Pending? {
            result.events.last { $0.kind == .schemas_advertised }?.advertisement?.pending
        }
        let selected = AgentCapabilitySet(tools: [echo])
        let first = try await turn("Inspect the echo tool.", visible: .none)
        let second = try await turn("Now with the echo selected.", visible: selected)
        let outcome = try await host.refreshDefinitions(session)
        _ = try await turn("Declared.", visible: selected)
        let fourth = try await turn("Echo withdrawn.", available: AgentCapabilitySet(tools: Standard.Tools.discovery), visible: .none)

        try Expect.false(
            first.events.contains { ($0.capabilityChanges ?? []).contains { $0.source == .tool_reveal } },
            "inspection reveals nothing"
        )
        let requests = await gateway.recordedRequests()
        let advertised = requests.map { request in request.tools.map(\.name) }
        try Expect.equal(advertised.count, 5, "two requests, then one per turn")
        try Expect.false(advertised[0].contains(echo.rawValue), "the echo tool is not declared")
        try Expect.equal(advertised[1], advertised[0], "inspection leaves the definitions as they are")
        try Expect.equal(advertised[2], advertised[0], "a new selection does not rewrite them")
        try Expect.equal(pending(second)?.added, [echo.rawValue], "it waits as pending")
        try Expect.true(outcome.contains("one cache miss"), "the operator is told the cost: \(outcome)")
        try Expect.true(advertised[3].contains(echo.rawValue), ":declare declares the selection at the next turn")
        try Expect.equal(advertised[4], advertised[3], "a withdrawn capability stays declared")
        try Expect.equal(pending(fourth)?.removed, [echo.rawValue], "its removal is pending")
        let note = requests[4].messages.last?.content.blocks.compactMap { block -> String? in
            guard case .text(let text) = block else { return nil }
            return text
        }.joined(separator: " ") ?? ""
        try Expect.true(
            note.contains("no longer available: \(echo.rawValue)"),
            "the withdrawal is announced in the history: \(note.prefix(300))"
        )
        return [.field("declared_tools", advertised[3].joined(separator: ","))]
    }

    /// A session started to review another reads that session's log with
    /// the Sessions log tools, not its own.
    static func runReviewingSession() async throws -> [TestDiagnostic] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reviewing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileSystem.default.remove(root) }
        let logs = Run.Log.Store(storage: .init(root: root.appendingPathComponent(".agentic")))
        let readLog = FunctionCall(
            id: "reviewing-read-log",
            name: Sessions.Tools.Log.identifier.rawValue,
            input: .object(["arguments": try JSONValue.encoding(Sessions.Tools.Log.Input())])
        )
        let gateway = GatewayFlowScriptedModelGateway(bufferedResponses: [
            .init(message: .init(role: .assistant, text: "reviewed work done"), stopReason: .end_turn),
            .init(message: .init(role: .assistant, content: .init(blocks: [.call(readLog)])), stopReason: .tool_use),
            .init(message: .init(role: .assistant, text: "read it"), stopReason: .end_turn),
        ])
        let host = AgentHost.Local(
            runtime: try await AgenticRuntime(application: Agentic.application("host-reviewing-fixture") {
                install(Sessions.self)
                modelProvider(AgentHostLocalModelProvider(modelGateway: gateway))
            }),
            logs: logs
        )
        let reviewed: AgentHost.Session.ID = "reviewed-session"
        let reviewer: AgentHost.Session.ID = "reviewer-session"
        _ = try await host.start(.init(id: reviewed))
        _ = try await host.submit(.init(session: reviewed, prompt: "Do the reviewed work."))
        _ = try await host.start(.init(id: reviewer, reviewing: reviewed))
        let tools = AgentCapabilitySet(tools: [Sessions.Tools.Log.identifier])
        let result = try await host.submit(.init(
            session: reviewer,
            prompt: "Read the log.",
            execution: .init(availableCapabilities: tools, visibleCapabilities: tools)
        ))
        let text = result.state.messages.flatMap(\.content.blocks).compactMap { block -> String? in
            guard case .result(let response) = block, response.call.id == readLog.id else { return nil }
            return response.modelText
        }.first ?? ""
        try Expect.true(
            text.contains("reviewed-session-turn-1") && !text.contains("reviewer-session-turn"),
            "the reviewer reads the reviewed session's log: \(text.prefix(300))"
        )
        return []
    }
}
