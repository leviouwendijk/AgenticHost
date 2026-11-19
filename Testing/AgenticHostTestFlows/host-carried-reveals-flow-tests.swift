import Agentic
import AgenticHost
import AgenticRuntime
import AgenticSessions
import AgenticStandard
import Foundation
import IO
import Primitives
import TestFlows

extension AgentHostLocalFlowTesting {
    /// A tool the model reveals in one turn is still in view in the next,
    /// so the next turn opens with the tools the last request carried;
    /// changing the operator's selection drops it.
    static func runCarriedReveals() async throws -> [TestDiagnostic] {
        let echo = GatewayFlowEchoTool.identifier
        let inspect = FunctionCall(
            id: "carried-inspect",
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
        ])
        let application = Agentic.application("host-carried-reveals-fixture") {
            tools {
                GatewayFlowEchoTool()
            }
            install(Standard.self)
            modelProvider(AgentHostLocalModelProvider(modelGateway: gateway))
        }
        let host = AgentHost.Local(runtime: try await AgenticRuntime(application: application))
        let session: AgentHost.Session.ID = "carried-reveals"
        _ = try await host.start(.init(id: session))

        let available = AgentCapabilitySet(tools: [echo] + Standard.Tools.discovery)
        func turn(_ prompt: String, visible: AgentCapabilitySet) async throws -> AgentExecutor.Result {
            let result = try await host.submit(.init(
                session: session,
                prompt: prompt,
                execution: .init(
                    availableCapabilities: available,
                    visibleCapabilities: visible,
                    configuration: .init(runLimits: .init(iterations: 3))
                )
            ))
            try Expect.true(result.isCompleted, "\(prompt) completes: \(result.phase) \(String(describing: result.failure)) \(String(describing: result.pendingApproval?.functionCall.name))")
            return result
        }
        _ = try await turn("Inspect the echo tool.", visible: .none)
        let second = try await turn("And again.", visible: .none)
        _ = try await turn("With another selection.", visible: .init(tools: [Standard.Tools.ListCapabilities.identifier]))
        let opening = second.events.first { $0.kind == .capability_changed }?.capabilityChanges ?? []
        try Expect.equal(
            opening.first { $0.reference == .tool(echo) }?.source,
            .carried,
            "the next turn reports the carried reveal as carried, not declared"
        )

        let advertised = await gateway.recordedRequests().map { request in request.tools.map(\.name) }
        try Expect.equal(advertised.count, 4, "two requests, then one per turn")
        try Expect.false(advertised[0].contains(echo.rawValue), "the echo tool starts hidden")
        try Expect.equal(
            advertised[1],
            advertised[0] + [echo.rawValue],
            "inspection reveals it, appended after the tools already advertised"
        )
        try Expect.equal(advertised[2], advertised[1], "the next turn opens with the tools the last request carried")
        try Expect.false(
            advertised[3].contains(echo.rawValue),
            "a new operator selection drops what was revealed under the old one"
        )
        return [.field("second_turn_tools", advertised[2].joined(separator: ","))]
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
