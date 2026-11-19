import Agentic
import AgenticHost
import AgenticRuntime
import AgenticStandard
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
        func turn(_ prompt: String, visible: AgentCapabilitySet) async throws {
            let result = try await host.submit(.init(
                session: session,
                prompt: prompt,
                execution: .init(
                    availableCapabilities: available,
                    visibleCapabilities: visible,
                    configuration: .init(runLimits: .init(iterations: 3))
                )
            ))
            try Expect.true(result.isCompleted, "\(prompt) completes")
        }
        try await turn("Inspect the echo tool.", visible: .none)
        try await turn("And again.", visible: .none)
        try await turn("With another selection.", visible: .init(tools: [Standard.Tools.ListCapabilities.identifier]))

        let advertised = await gateway.recordedRequests().map { request in request.tools.map(\.name) }
        try Expect.equal(advertised.count, 4, "two requests, then one per turn")
        try Expect.false(advertised[0].contains(echo.rawValue), "the echo tool starts hidden")
        try Expect.true(advertised[1].contains(echo.rawValue), "inspection reveals it")
        try Expect.equal(advertised[2], advertised[1], "the next turn opens with the tools the last request carried")
        try Expect.false(
            advertised[3].contains(echo.rawValue),
            "a new operator selection drops what was revealed under the old one"
        )
        return [.field("second_turn_tools", advertised[2].joined(separator: ","))]
    }
}
