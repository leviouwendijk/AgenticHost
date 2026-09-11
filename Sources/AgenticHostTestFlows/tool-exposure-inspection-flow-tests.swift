import Agentic
import AgenticExecution
import AgenticRuntime
import AgenticTools
import Primitives
import TestFlows

extension AgenticRuntimeToolExposureFlowTesting {
    static func runExposureInspection()
        async throws
        -> [TestFlowDiagnostic]
    {
        let registry = try Agentic.tool.registry {
            GatewayFlowEchoTool()
        }

        let inspectCall = AgentToolCall(
            id: "runtime-inspect-tool-exposure",
            name:
                InspectToolExposureTool
                    .identifier
                    .rawValue,
            input: try JSONToolBridge.encode(
                InspectToolExposureToolInput()
            )
        )
        let inspectResponse = AgentResponse(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .tool_call(
                            inspectCall
                        ),
                    ]
                )
            ),
            stopReason: .tool_use
        )
        let finalResponse = AgentResponse(
            message: .init(
                role: .assistant,
                text: "done"
            ),
            stopReason: .end_turn
        )
        let adapter =
            GatewayFlowScriptedModelGateway(
                streamBatches: [
                    [
                        .toolcall(
                            inspectCall
                        ),
                        .completed(
                            inspectResponse
                        ),
                    ],
                    [
                        .completed(
                            finalResponse
                        ),
                    ],
                ]
            )
        let runner = AgentRunner(
            model: .init(
                invoker: GatewayFlowModelInvoker(
                    gateway: adapter,
                    model: "scripted"
                )
            ),
            configuration: .init(
                maximumIterations: 2,
                toolExposure: .all,
                responseDelivery: .stream
            ),
            tooling: .init(
                registry: registry
            )
        )

        let result = try await runner.run(
            AgentRequest(
                messages: [
                    .init(
                        role: .user,
                        text: "Inspect exposure."
                    ),
                ]
            ),
            sessionID:
                "runtime-tool-exposure-inspection"
        )

        let toolResults = result.state.messages
            .flatMap(\.content.blocks)
            .compactMap {
                block -> AgentToolResult? in

                guard
                    case .tool_result(let value) =
                        block,
                    value.toolCallID ==
                        inspectCall.id
                else {
                    return nil
                }

                return value
            }

        try Expect.equal(
            toolResults.count,
            1,
            "runtime exposure inspection result count"
        )

        let inspection =
            try JSONToolBridge.decode(
                InspectToolExposureToolOutput.self,
                from: toolResults[0].output
            )

        try Expect.equal(
            inspection.registeredModelFacingCount,
            3,
            "runtime binds final all-mode registry including exposure inspector"
        )
        try Expect.equal(
            inspection.exposedCount,
            3,
            "all mode exposes complete runtime registry"
        )

        let findCall = AgentToolCall(
            id: "runtime-find-exposure-inspector",
            name:
                FindToolsTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                FindToolsToolInput(
                    query:
                        InspectToolExposureTool
                            .identifier
                            .rawValue,
                    maximumResults: 1
                )
            )
        )
        let findResponse = AgentResponse(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .tool_call(
                            findCall
                        ),
                    ]
                )
            ),
            stopReason: .tool_use
        )
        let discoveryAdapter =
            GatewayFlowScriptedModelGateway(
                streamBatches: [
                    [
                        .toolcall(
                            findCall
                        ),
                        .completed(
                            findResponse
                        ),
                    ],
                    [
                        .completed(
                            finalResponse
                        ),
                    ],
                ]
            )
        let discoveryRunner = AgentRunner(
            model: .init(
                invoker: GatewayFlowModelInvoker(
                    gateway: discoveryAdapter,
                    model: "scripted"
                )
            ),
            configuration: .init(
                maximumIterations: 2,
                toolExposure: .discoveryOnly,
                responseDelivery: .stream
            ),
            tooling: .init(
                registry: registry
            )
        )

        _ = try await discoveryRunner.run(
            AgentRequest(
                messages: [
                    .init(
                        role: .user,
                        text:
                            "Discover exposure inspection."
                    ),
                ]
            ),
            sessionID:
                "runtime-tool-exposure-discovery"
        )

        let requests =
            await discoveryAdapter
                .recordedRequests()

        try Expect.equal(
            requests.count,
            2,
            "discovery request count"
        )
        try Expect.equal(
            requests[0].tools
                .map(\.name)
                .contains(
                    InspectToolExposureTool
                        .identifier
                        .rawValue
                ),
            false,
            "exposure inspector is not a discovery seed"
        )
        try Expect.equal(
            requests[1].tools
                .map(\.name)
                .contains(
                    InspectToolExposureTool
                        .identifier
                        .rawValue
                ),
            true,
            "find_tools can discover and activate exposure inspection"
        )

        let optedOut = try Agentic.tool.registry(
            configuration: .init(
                includeIntrinsicTools: false
            )
        ) {
            GatewayFlowEchoTool()
        }
        let optedOutAdapter =
            GatewayFlowScriptedModelGateway(
                streamBatches: [
                    [
                        .completed(
                            finalResponse
                        ),
                    ],
                ]
            )
        let optedOutRunner = AgentRunner(
            model: .init(
                invoker: GatewayFlowModelInvoker(
                    gateway: optedOutAdapter,
                    model: "scripted"
                )
            ),
            configuration: .init(
                maximumIterations: 1,
                toolExposure: .all,
                responseDelivery: .stream
            ),
            tooling: .init(
                registry: optedOut
            )
        )

        _ = try await optedOutRunner.run(
            AgentRequest(
                messages: [
                    .init(
                        role: .user,
                        text: "Use configured tools."
                    ),
                ]
            ),
            sessionID:
                "runtime-tool-exposure-opt-out"
        )

        let optedOutRequests =
            await optedOutAdapter
                .recordedRequests()
        let optedOutRequest =
            try Expect.notNil(
                optedOutRequests.first,
                "opt-out request"
            )

        try Expect.equal(
            optedOutRequest.tools
                .map(\.name)
                .contains(
                    InspectToolExposureTool
                        .identifier
                        .rawValue
                ),
            false,
            "registry intrinsic opt-out suppresses runtime exposure inspection"
        )

        return [
            .field(
                "registered",
                String(
                    inspection
                        .registeredModelFacingCount
                )
            ),
        ]
    }
}
