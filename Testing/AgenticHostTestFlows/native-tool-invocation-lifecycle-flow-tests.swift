import Agentic
import AgenticRuntime
import AgenticStandard
import Workspace
import Foundation
import Primitives
import Schema
import Macros
import TestFlows

extension AgenticRuntimeFlowTesting {
    static func runNativeToolInvocationLifecycle()
        async throws
        -> [TestDiagnostic]
    {
        try await proveNativeLiveApproval()
        try await proveNativeDurableApproval()
        try await proveNativeDiscoveryBoundary()

        return [
            .field(
                "live_approval",
                "same invocation"
            ),
            .field(
                "durable_approval",
                "suspend and resume"
            ),
            .field(
                "discovery",
                "new invocation boundary"
            ),
        ]
    }
}

private extension AgenticRuntimeFlowTesting {
    static func proveNativeLiveApproval() async throws {
        let toolProbe = NativeLifecycleToolProbe()
        var registry = ToolRegistry()

        try registry.register(
            NativeLifecycleMutateTool(
                probe: toolProbe
            )
        )

        let capabilityState = AgentCapabilityState(
            installed: AgentCapabilitySet(
                tools: [
                    NativeLifecycleMutateTool.definition.identifier,
                ]
            ),
            available: AgentCapabilitySet(
                tools: [
                    NativeLifecycleMutateTool.definition.identifier,
                ]
            ),
            visible: AgentCapabilitySet(
                tools: [
                    NativeLifecycleMutateTool.definition.identifier,
                ]
            )
        )
        let modelProbe = NativeLifecycleModelProbe()
        let adapter = NativeLifecycleGateway(
            operation: { request, context in
                _ = await modelProbe.record(
                    request
                )

                let resolver = try nativeLifecycleResolver(
                    context
                )

                _ = try await resolver.resolve(
                    try nativeLifecycleCall(
                        id: "native-live-approval-call",
                        tool: NativeLifecycleMutateTool.definition.identifier
                    )
                )

                return nativeLifecycleFinalResponse(
                    "native live approval complete"
                )
            }
        )
        let executor = ToolLoopExecutor(
            model: .init(
                invoker: GatewayFlowModelInvoker(
                    gateway: adapter,
                    model: "native-lifecycle"
                )
            ),
            configuration: .init(
                autonomyMode: .auto_observe
            ),
            tooling: .init(
                registry: registry,
                approvalHandler: NativeLifecycleApprovalHandler(
                    decision: .approved
                )
            ),
            capabilityState: capabilityState
        )

        let result = try await executor.run(
            nativeLifecycleRequest(),
            sessionID: "native-live-approval"
        )

        try Expect.equal(
            result.isCompleted,
            true,
            "native live approval completes without leaving the provider invocation"
        )
        try Expect.equal(
            await modelProbe.invocationCount(),
            1,
            "native live approval uses one model invocation"
        )
        try Expect.equal(
            await toolProbe.invocationCount(),
            1,
            "native live approval executes the tool once"
        )
        try Expect.equal(
            nativeLifecycleToolResults(
                result.state
            ).map(
                \.toolCallID
            ),
            [
                "native-live-approval-call",
            ],
            "native live approval journals the tool result into durable loop state"
        )
        try Expect.equal(
            result.toolUses.map(\.id),
            [
                "native-live-approval-call",
            ],
            "native live approval preserves the exact tool call in run trace"
        )
        try Expect.equal(
            result.toolUses.first?.disposition,
            Optional(AgentToolUseDisposition.executed),
            "native live approval preserves executed disposition"
        )
        try Expect.equal(
            result.toolUses.first?.preflight != nil,
            true,
            "native live approval preserves preflight"
        )
        try Expect.equal(
            result.toolUses.first?.result?.toolCallID,
            Optional("native-live-approval-call"),
            "native live approval preserves semantic tool result"
        )
    }

    static func proveNativeDurableApproval() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentic-native-durable-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(
                at: root
            )
        }

        let historyStore = FileHistoryStore(
            sessionsdir: root
        )
        let toolProbe = NativeLifecycleToolProbe()
        var registry = ToolRegistry()

        try registry.register(
            NativeLifecycleDurableMutateTool(
                probe: toolProbe
            )
        )

        let capabilityState = AgentCapabilityState(
            installed: AgentCapabilitySet(
                tools: [
                    NativeLifecycleDurableMutateTool.definition.identifier,
                ]
            ),
            available: AgentCapabilitySet(
                tools: [
                    NativeLifecycleDurableMutateTool.definition.identifier,
                ]
            ),
            visible: AgentCapabilitySet(
                tools: [
                    NativeLifecycleDurableMutateTool.definition.identifier,
                ]
            )
        )
        let modelProbe = NativeLifecycleModelProbe()
        let adapter = NativeLifecycleGateway(
            operation: { request, context in
                let invocation = await modelProbe.record(
                    request
                )

                if invocation == 1 {
                    let resolver = try nativeLifecycleResolver(
                        context
                    )

                    _ = try await resolver.resolve(
                        try nativeLifecycleCall(
                            id: "native-durable-approval-call",
                            tool: NativeLifecycleDurableMutateTool.definition.identifier
                        )
                    )

                    throw NativeLifecycleFailure
                        .expectedProviderBoundary
                }

                return nativeLifecycleFinalResponse(
                    "native durable approval complete"
                )
            }
        )
        let executor = ToolLoopExecutor(
            model: .init(
                invoker: GatewayFlowModelInvoker(
                    gateway: adapter,
                    model: "native-lifecycle"
                )
            ),
            configuration: .init(
                autonomyMode: .auto_observe,
                historyPersistenceMode: .checkpointmutation
            ),
            tooling: .init(
                registry: registry
            ),
            capabilityState: capabilityState,
            recording: .init(
                historyStore: historyStore
            )
        )
        let sessionID = "native-durable-approval"

        let initial = try await executor.run(
            nativeLifecycleRequest(),
            sessionID: sessionID
        )

        try Expect.equal(
            initial.pendingApproval?.toolCall.id,
            "native-durable-approval-call",
            "unresolved native review becomes the ordinary durable pending approval"
        )
        try Expect.equal(
            initial.isFailed,
            false,
            "unresolved native review is not recorded as a model failure"
        )
        try Expect.equal(
            initial.toolUses.map(\.id),
            [
                "native-durable-approval-call",
            ],
            "suspended native review is visible in the run trace"
        )
        try Expect.equal(
            initial.toolUses.first?.disposition,
            Optional(AgentToolUseDisposition.suspended_for_approval),
            "suspended native review preserves its disposition"
        )
        try Expect.equal(
            initial.toolUses.first?.preflight != nil,
            true,
            "suspended native review preserves preflight"
        )
        try Expect.equal(
            await toolProbe.invocationCount(),
            0,
            "durable native approval does not execute before approval"
        )

        let checkpoint = try Expect.notNil(
            try await historyStore.loadCheckpoint(
                sessionID: sessionID
            ),
            "native durable approval checkpoint"
        )

        let resumed = try await executor.resume(
            checkpoint,
            approvalDecision: .approved
        )

        try Expect.equal(
            resumed.isCompleted,
            true,
            "approved durable native call resumes to completion"
        )
        try Expect.equal(
            await toolProbe.invocationCount(),
            1,
            "approved durable native call executes exactly once"
        )
        try Expect.equal(
            await modelProbe.invocationCount(),
            2,
            "durable approval reconstructs through a second provider invocation"
        )
        try Expect.equal(
            resumed.toolUses.map(\.id),
            [
                "native-durable-approval-call",
            ],
            "resumed native approval retains one durable tool-use record"
        )
        try Expect.equal(
            resumed.toolUses.first?.disposition,
            Optional(AgentToolUseDisposition.executed),
            "resumed native approval upgrades the trace to executed"
        )
        try Expect.equal(
            resumed.toolUses.first?.result?.toolCallID,
            Optional("native-durable-approval-call"),
            "resumed native approval preserves its result"
        )
    }

    static func proveNativeDiscoveryBoundary() async throws {
        let toolProbe = NativeLifecycleToolProbe()
        var registry = ToolRegistry()

        try registry.register(
            NativeLifecycleEchoTool(
                probe: toolProbe
            )
        )

        let capabilityState = AgentCapabilityState(
            installed: AgentCapabilitySet(
                tools: [
                    NativeLifecycleEchoTool.definition.identifier,
                    Standard.Tools.FindCapabilities.identifier,
                ]
            ),
            available: AgentCapabilitySet(
                tools: [
                    NativeLifecycleEchoTool.definition.identifier,
                    Standard.Tools.FindCapabilities.identifier,
                ]
            ),
            visible: AgentCapabilitySet(
                tools: [
                    NativeLifecycleEchoTool.definition.identifier,
                ]
            )
        )

        try registry.register(
            Standard.Tools.FindCapabilities()
        )

        let modelProbe = NativeLifecycleModelProbe()
        let adapter = NativeLifecycleGateway(
            operation: { request, context in
                let invocation = await modelProbe.record(
                    request
                )
                let resolver = try nativeLifecycleResolver(
                    context
                )

                if invocation == 1 {
                    _ = try await resolver.resolve(
                        ToolCall(
                            id: "native-find-tools-call",
                            tool: Standard.Tools.FindCapabilities.identifier,
                            input: .object([
                                "arguments": try JSONValue.encoding(
                                    Standard.Tools.FindCapabilities.Input(
                                        query: "native_lifecycle_echo",
                                        maximumResults: 1
                                    )
                                ),
                            ])
                        )
                    )

                    throw NativeLifecycleFailure
                        .expectedProviderBoundary
                }

                guard request.tools.contains(where: { definition in
                    definition.name == "native_lifecycle_echo"
                }) else {
                    throw NativeLifecycleFailure
                        .discoveredToolNotAdvertised
                }

                _ = try await resolver.resolve(
                    try nativeLifecycleCall(
                        id: "native-discovered-echo-call",
                        tool: NativeLifecycleEchoTool.definition.identifier
                    )
                )

                return nativeLifecycleFinalResponse(
                    "native discovery complete"
                )
            }
        )
        let executor = ToolLoopExecutor(
            model: .init(
                invoker: GatewayFlowModelInvoker(
                    gateway: adapter,
                    model: "native-lifecycle"
                )
            ),
            configuration: .init(
                autonomyMode: .auto_observe
            ),
            tooling: .init(
                registry: registry
            ),
            capabilityState: capabilityState
        )

        let result = try await executor.run(
            nativeLifecycleRequest(),
            sessionID: "native-discovery-boundary"
        )

        try Expect.equal(
            result.isCompleted,
            true,
            "native discovery boundary reconstructs and completes"
        )
        try Expect.equal(
            await modelProbe.invocationCount(),
            2,
            "exposure mutation deliberately creates a second provider invocation"
        )
        try Expect.equal(
            await toolProbe.invocationCount(),
            1,
            "tool discovered across the boundary executes exactly once"
        )
        try Expect.equal(
            nativeLifecycleToolResults(
                result.state
            ).map(
                \.toolCallID
            ),
            [
                "native-find-tools-call",
                "native-discovered-echo-call",
            ],
            "find_capabilities and the discovered tool both remain in durable state"
        )
        try Expect.equal(
            result.toolUses.map(\.id),
            [
                "native-find-tools-call",
                "native-discovered-echo-call",
            ],
            "native discovery preserves both exact model tool calls in run trace"
        )
    }
}

private struct NativeLifecycleGateway:
    AgentModelGateway
{
    let identifier: AgentModelGatewayIdentifier = "native_lifecycle_fixture"
    let operation:
        @Sendable (
            AgentRequest,
            AgentModelInvocationContext
        ) async throws -> AgentResponse

    var response: AgentModelResponseProviding {
        NativeLifecycleResponseProvider(
            operation: operation
        )
    }
}

private struct NativeLifecycleResponseProvider:
    AgentModelResponseProviding
{
    let operation:
        @Sendable (
            AgentRequest,
            AgentModelInvocationContext
        ) async throws -> AgentResponse

    func buffered(
        request: AgentRequest,
        route _: AgentModelRoute,
        context: AgentModelInvocationContext
    ) async throws -> AgentResponse {
        try await operation(
            request,
            context
        )
    }

    func stream(
        request: AgentRequest,
        route _: AgentModelRoute,
        context: AgentModelInvocationContext
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await operation(
                        request,
                        context
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
}

private actor NativeLifecycleModelProbe {
    private var requests: [AgentRequest] = []

    func record(
        _ request: AgentRequest
    ) -> Int {
        requests.append(
            request
        )
        return requests.count
    }

    func invocationCount() -> Int {
        requests.count
    }
}

private actor NativeLifecycleToolProbe {
    private var count = 0

    func recordInvocation() {
        count += 1
    }

    func invocationCount() -> Int {
        count
    }
}

@JSONSchema
private struct NativeLifecycleInput: HashableSource {
    init() {}
}

@JSONSchema
private struct NativeLifecycleOutput: HashableResult {
    init() {}
}

private protocol NativeLifecycleFixtureTool: Tool
where Input == NativeLifecycleInput, Output == NativeLifecycleOutput {
    var probe: NativeLifecycleToolProbe { get }
}

private extension NativeLifecycleFixtureTool {
    func call(
        _ input: Input,
        in _: ToolContext
    ) async throws -> Output {
        _ = input
        await probe.recordInvocation()
        return .init()
    }
}

private struct NativeLifecycleMutateTool: NativeLifecycleFixtureTool {
    static let definition = ToolDefinition(
        identifier: .init(rawValue: "native_lifecycle_mutate"),
        purpose: "Native lifecycle bounded mutation fixture.",
        risk: .boundedmutate
    )

    let probe: NativeLifecycleToolProbe
}

private struct NativeLifecycleDurableMutateTool: NativeLifecycleFixtureTool {
    static let definition = ToolDefinition(
        identifier: .init(rawValue: "native_lifecycle_durable_mutate"),
        purpose: "Native lifecycle durable mutation fixture.",
        risk: .boundedmutate
    )

    let probe: NativeLifecycleToolProbe
}

private struct NativeLifecycleEchoTool: NativeLifecycleFixtureTool {
    static let definition = ToolDefinition(
        identifier: .init(rawValue: "native_lifecycle_echo"),
        purpose: "Echo a native lifecycle discovery fixture.",
        risk: .observe
    )

    let probe: NativeLifecycleToolProbe
}

private struct NativeLifecycleApprovalHandler:
    ToolApprovalHandler
{
    let decision: ApprovalDecision

    func decide(
        on review: ToolInvocation.Review
    ) async throws -> ApprovalDecision {
        decision
    }
}

private enum NativeLifecycleFailure:
    Error
{
    case missingInvocationContext
    case unsupportedStream
    case expectedProviderBoundary
    case discoveredToolNotAdvertised
}

private func nativeLifecycleResolver(
    _ context: AgentModelInvocationContext
) throws -> any ToolCallResolver {
    guard let resolver = context.toolCallResolver else {
        throw NativeLifecycleFailure
            .missingInvocationContext
    }

    return resolver
}

private func nativeLifecycleCall(
    id: String,
    tool: ToolIdentifier
) throws -> ToolCall {
    ToolCall(
        id: id,
        tool: tool,
        input: .object([
            "arguments": try JSONValue.encoding(
                NativeLifecycleInput()
            ),
        ])
    )
}

private func nativeLifecycleRequest() -> AgentRequest {
    AgentRequest(
        messages: [
            .init(
                role: .user,
                text: "Exercise native tool invocation lifecycle."
            ),
        ]
    )
}

private func nativeLifecycleFinalResponse(
    _ text: String
) -> AgentResponse {
    AgentResponse(
        message: .init(
            role: .assistant,
            text: text
        ),
        stopReason: .end_turn
    )
}

private func nativeLifecycleToolResults(
    _ state: AgentLoopState
) -> [ToolResult] {
    state.messages
        .flatMap(
            \.content.blocks
        )
        .compactMap { block in
            guard case .tool_result(let result) = block else {
                return nil
            }

            return result
        }
}
