import Agentic
import AgenticHost
import AgenticStandard
import AgenticRuntime
import Foundation
import Macros
import Primitives
import Schema
import TestFlows

private actor SessionServiceProbe {}

@JSONSchema
private struct SessionServiceInput: Sendable, Codable, Hashable {
    init() {}
}

private struct SessionServiceTool: Tool {
    typealias Input = SessionServiceInput
    typealias Output = JSONValue

    static let definition = ToolDefinition(
        identifier: "fixture.session_services",
        purpose: "Check trusted services in an agent tool execution context.",
        risk: .observe
    )

    func call(_ input: Input, in context: ToolContext) async throws -> Output {
        _ = try context.require(SessionServiceProbe.self)
        return .bool(true)
    }
}

private final class SessionServiceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var created: [String] = []

    func construct(for session: String) throws -> ToolServices {
        lock.withLock {
            created.append(session)
        }
        return try ToolServices().inserting(SessionServiceProbe())
    }

    func snapshot() -> [String] {
        lock.withLock { created }
    }
}

private enum SessionServiceTestFailure: Error {
    case invalid_lifecycle
}

enum AgenticHostSessionServicesFlow {
    static func run() async throws -> [TestDiagnostic] {
        let application = Agentic.application("session-service-lifecycle-test") {
            install(Standard.self)
        }
        let runtime = try await AgenticRuntime(application: application)
        let counter = SessionServiceCounter()
        let host = AgentHost.Local(runtime: runtime, services: { id in
            try counter.construct(for: id.rawValue)
        })
        _ = try await host.start(.init(id: "alpha"))
        _ = try await host.start(.init(id: "beta"))
        let first = counter.snapshot()
        guard first == ["alpha", "beta"] else {
            throw SessionServiceTestFailure.invalid_lifecycle
        }
        _ = try await host.sessions()
        guard counter.snapshot() == first else {
            throw SessionServiceTestFailure.invalid_lifecycle
        }
        try await verifyRuntimeExecution()
        return [
            .field("created_once_per_session", "true"),
            .field("runtime_service_propagation", "true"),
        ]
    }

    private static func verifyRuntimeExecution() async throws {
        let identifier = SessionServiceTool.definition.identifier
        let call = ToolCall(
            id: "runtime-service-probe",
            tool: identifier,
            input: .object([:])
        )
        let gateway = GatewayFlowScriptedModelGateway(
            streamBatches: [
                [
                    .toolcall(call),
                    .completed(AgentResponse(
                        message: .init(
                            role: .assistant,
                            content: .init(blocks: [.tool_call(call)])
                        ),
                        stopReason: .tool_use
                    )),
                ],
                [
                    .completed(AgentResponse(
                        message: .init(role: .assistant, text: "complete"),
                        stopReason: .end_turn
                    )),
                ],
            ]
        )
        let services = try ToolServices().inserting(SessionServiceProbe())
        let tooling = RuntimeServices.Tooling(
            registry: try ToolRegistry { SessionServiceTool() },
            services: services
        )
        _ = try tooling.using(workspace: nil)
            .using(catalog: .none)
            .using(registry: tooling.registry)
            .services.require(SessionServiceProbe.self)
        let capabilities = AgentCapabilitySet(tools: [identifier])
        let runner = AgentRunner(
            model: .init(
                invoker: GatewayFlowModelInvoker(
                    gateway: gateway,
                    model: "scripted"
                )
            ),
            configuration: .init(
                runLimits: .init(iterations: 2),
                responseDelivery: .stream
            ),
            tooling: tooling,
            capabilityState: AgentCapabilityState(
                installed: capabilities,
                available: capabilities,
                visible: capabilities
            )
        )
        _ = try await runner.run(
            .init(messages: [.init(role: .user, text: "Check service")]),
            sessionID: "runtime-service-propagation"
        )
        let results = await gateway.recordedRequests()
            .flatMap(\.messages)
            .flatMap(\.content.blocks)
            .compactMap { block -> ToolCall.Response? in
                guard case .tool_result(let result) = block else {
                    return nil
                }
                return result
            }
        guard results.count == 1, !results[0].isError else {
            throw SessionServiceTestFailure.invalid_lifecycle
        }
    }
}
