import Agentic
import AgenticRuntime
import AgenticStandard
import Foundation
import Primitives
import TestFlows

enum AgenticRuntimeToolExposureFlowTesting {
    static func runExplicitEnforcement() async throws -> [TestDiagnostic] {
        let store = GatewayFlowScratchpadStore()
        let hiddenTool = GatewayFlowScratchpadTool(
            store: store
        )
        let hiddenCall = FunctionCall(
            id: "runtime-hidden-tool-call",
            name: GatewayFlowScratchpadTool.identifier.rawValue,
            input: try JSONValue.encoding(
                GatewayFlowScratchpadPutInput(
                    text: "must not execute"
                )
            )
        )
        let firstResponse = AgentResponse(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .call(
                            hiddenCall
                        ),
                    ]
                )
            ),
            stopReason: .tool_use
        )
        let finalResponse = AgentResponse(
            message: .init(
                role: .assistant,
                text: "hidden call rejected"
            ),
            stopReason: .end_turn
        )
        let adapter = GatewayFlowScriptedModelGateway(
            streamBatches: [
                [
                    .call(
                        hiddenCall
                    ),
                    .completed(
                        firstResponse
                    ),
                ],
                [
                    .completed(
                        finalResponse
                    ),
                ],
            ]
        )
        let capabilityState = AgentCapabilityState(
            installed: AgentCapabilitySet(
                tools: [
                    GatewayFlowEchoTool.identifier,
                    GatewayFlowScratchpadTool.identifier,
                ]
            ),
            available: AgentCapabilitySet(
                tools: [
                    GatewayFlowEchoTool.identifier,
                    GatewayFlowScratchpadTool.identifier,
                ]
            ),
            visible: AgentCapabilitySet(
                tools: [
                    GatewayFlowEchoTool.identifier,
                ]
            )
        )
        let executor = AgentExecutor(
            model: .init(
                invoker: GatewayFlowModelInvoker(
                    gateway: adapter,
                    model: "scripted"
                )
            ),
            configuration: .init(
                runLimits: .init(iterations: 2),
                responseDelivery: .stream
            ),
            tooling: .init(
                registry: try ToolRegistry {
                    GatewayFlowEchoTool()
                    hiddenTool
                }
            ),
            capabilityState: capabilityState
        )

        _ = try await executor.run(
            AgentRequest(
                messages: [
                    .init(
                        role: .user,
                        text: "Attempt the hidden tool."
                    ),
                ]
            ),
            sessionID: "runtime-tool-exposure-explicit"
        )
        let requests = await adapter.recordedRequests()
        let values = await store.all()
        let toolResults = requests
            .flatMap(
                \.messages
            )
            .flatMap(
                \.content.blocks
            )
            .compactMap { block -> FunctionCall.Response? in
                guard case .result(let result) = block else {
                    return nil
                }

                return result
            }

        try Expect.equal(
            requests.count,
            2,
            "explicit exposure model request count"
        )

        for request in requests {
            try Expect.equal(
                request.tools.map(
                    \.name
                ),
                [
                    GatewayFlowEchoTool.identifier.rawValue,
                ],
                "explicit exposure advertises only the selected model-facing tool"
            )
        }

        try Expect.isEmpty(
            values,
            "hidden mutating tool never executes"
        )

        let hiddenResult = try Expect.notNil(
            toolResults.last,
            "hidden-call error result"
        )

        try Expect.equal(
            hiddenResult.isError,
            true,
            "hidden model call becomes an error result"
        )

        try Expect.contains(
            String(
                describing: hiddenResult.output
            ),
            "not visible to the current Agent",
            "hidden-call error explains exposure rejection"
        )

        return [
            .field(
                "advertised",
                requests.first?.tools.map(\.name).joined(separator: ",")
                    ?? "<none>"
            ),
            .field(
                "hidden_executed",
                String(!values.isEmpty)
            ),
        ]
    }

    static func runVisibleDiscovery() async throws -> [TestDiagnostic] {
        let store = GatewayFlowScratchpadStore()
        let finalResponse = AgentResponse(
            message: .init(
                role: .assistant,
                text: "seeded"
            ),
            stopReason: .end_turn
        )
        let adapter = GatewayFlowScriptedModelGateway(
            streamBatches: [
                [
                    .completed(
                        finalResponse
                    ),
                ],
            ]
        )
        let capabilityState = AgentCapabilityState(
            installed: AgentCapabilitySet(
                tools: [
                    GatewayFlowEchoTool.identifier,
                    GatewayFlowScratchpadTool.identifier,
                    Standard.Tools.FindCapabilities.identifier,
                ]
            ),
            available: AgentCapabilitySet(
                tools: [
                    GatewayFlowEchoTool.identifier,
                    GatewayFlowScratchpadTool.identifier,
                    Standard.Tools.FindCapabilities.identifier,
                ]
            ),
            visible: AgentCapabilitySet(
                tools: [
                    GatewayFlowEchoTool.identifier,
                    Standard.Tools.FindCapabilities.identifier,
                ]
            )
        )
        let executor = AgentExecutor(
            model: .init(
                invoker: GatewayFlowModelInvoker(
                    gateway: adapter,
                    model: "scripted"
                )
            ),
            configuration: .init(
                runLimits: .init(iterations: 1),
                responseDelivery: .stream
            ),
            tooling: .init(
                registry: try ToolRegistry {
                    GatewayFlowEchoTool()
                    GatewayFlowScratchpadTool(
                        store: store
                    )
                    Standard.Tools.FindCapabilities()
                }
            ),
            capabilityState: capabilityState
        )

        _ = try await executor.run(
            AgentRequest(
                messages: [
                    .init(
                        role: .user,
                        text: "Inspect the seeded tool surface."
                    ),
                ]
            ),
            sessionID: "runtime-tool-exposure-visible-tool"
        )

        let requests = await adapter.recordedRequests()
        let advertised = try Expect.notNil(
            requests.first,
            "visible-tool request"
        ).tools.map(
            \.name
        )

        try Expect.equal(
            advertised,
            [
                GatewayFlowEchoTool.identifier.rawValue,
                Standard.Tools.FindCapabilities.identifier.rawValue,
            ],
            "visible-tool discovery exposes visible tools plus find_capabilities"
        )

        return [
            .field(
                "advertised",
                advertised.joined(separator: ",")
            ),
        ]
    }

    static func runApprovalResumePersistence() async throws -> [TestDiagnostic] {
        let store = GatewayFlowScratchpadStore()
        let findCall = FunctionCall(
            id: "runtime-resume-find-capabilities",
            name: Standard.Tools.FindCapabilities.identifier.rawValue,
            input: .object([
                "arguments": try JSONValue.encoding(
                    Standard.Tools.FindCapabilities.Input(
                        query: GatewayFlowScratchpadTool.identifier.rawValue,
                        maximumResults: 1
                    )
                ),
            ])
        )
        let mutateCall = FunctionCall(
            id: "runtime-resume-scratchpad-put",
            name: GatewayFlowScratchpadTool.identifier.rawValue,
            input: .object([
                "arguments": try JSONValue.encoding(
                    GatewayFlowScratchpadPutInput(
                        text: "approved after discovery"
                    )
                ),
            ])
        )
        let findResponse = AgentResponse(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .call(
                            findCall
                        ),
                    ]
                )
            ),
            stopReason: .tool_use
        )
        let mutateResponse = AgentResponse(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .call(
                            mutateCall
                        ),
                    ]
                )
            ),
            stopReason: .tool_use
        )
        let finalResponse = AgentResponse(
            message: .init(
                role: .assistant,
                text: "approved discovery resumed"
            ),
            stopReason: .end_turn
        )
        let adapter = GatewayFlowScriptedModelGateway(
            streamBatches: [
                [
                    .call(
                        findCall
                    ),
                    .completed(
                        findResponse
                    ),
                ],
                [
                    .call(
                        mutateCall
                    ),
                    .completed(
                        mutateResponse
                    ),
                ],
                [
                    .completed(
                        finalResponse
                    ),
                ],
            ]
        )
        let sessionsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentic-runtime-exposure-resume-\(UUID().uuidString)",
                isDirectory: true
            )
        let historyStore = FileHistoryStore(
            sessionsdir: sessionsDirectory
        )
        defer {
            try? FileManager.default.removeItem(
                at: sessionsDirectory
            )
        }
        let sessionID = "runtime-tool-exposure-approval-resume"
        // The host explicitly exposes the mutation tool. Finding it does not.
        let capabilityState = AgentCapabilityState(
            installed: AgentCapabilitySet(
                tools: [
                    GatewayFlowScratchpadTool.identifier,
                    Standard.Tools.FindCapabilities.identifier,
                ]
            ),
            available: AgentCapabilitySet(
                tools: [
                    GatewayFlowScratchpadTool.identifier,
                    Standard.Tools.FindCapabilities.identifier,
                ]
            ),
            visible: AgentCapabilitySet(
                tools: [
                    GatewayFlowScratchpadTool.identifier,
                    Standard.Tools.FindCapabilities.identifier,
                ]
            )
        )
        let executor = AgentExecutor(
            model: .init(
                invoker: GatewayFlowModelInvoker(
                    gateway: adapter,
                    model: "scripted"
                )
            ),
            configuration: .init(
                runLimits: .init(iterations: 4),
                autonomyMode: .auto_observe,
                historyPersistenceMode: .checkpointmutation,
                responseDelivery: .stream
            ),
            tooling: .init(
                registry: try ToolRegistry {
                    GatewayFlowScratchpadTool(
                        store: store
                    )
                    Standard.Tools.FindCapabilities()
                },
                catalog: Catalog(
                    declarations: [
                        .tool(GatewayFlowScratchpadTool.definition),
                        .tool(Standard.Tools.FindCapabilities.definition),
                    ]
                )
            ),
            capabilityState: capabilityState,
            recording: .init(
                historyStore: historyStore
            )
        )

        let initialResult = try await executor.run(
            AgentRequest(
                messages: [
                    .init(
                        role: .user,
                        text: "Discover the scratchpad tool and use it."
                    ),
                ]
            ),
            sessionID: sessionID
        )
        let pendingApproval = try Expect.notNil(
            initialResult.pendingApproval,
            "explicitly exposed bounded mutation suspends for approval"
        )

        try Expect.equal(
            pendingApproval.functionCall.name,
            GatewayFlowScratchpadTool.identifier.rawValue,
            "approval belongs to the explicitly exposed tool"
        )
        try Expect.isEmpty(
            await store.all(),
            "discovered mutation has not executed before approval"
        )

        let checkpoint = try Expect.notNil(
            try await historyStore.loadCheckpoint(
                sessionID: sessionID
            ),
            "persisted exposed-tool checkpoint"
        )
        let persistedExposure = checkpoint.capabilities.visible.tools
            .map(\.rawValue)
            .sorted()

        try Expect.equal(
            persistedExposure,
            [
                GatewayFlowScratchpadTool.identifier.rawValue,
                Standard.Tools.FindCapabilities.identifier.rawValue,
            ].sorted(),
            "checkpoint retains explicitly exposed tool surface"
        )

        let requestsBeforeResume = await adapter.recordedRequests()

        try Expect.equal(
            requestsBeforeResume.count,
            2,
            "discovery and authorized-tool proposal precede suspension"
        )
        try Expect.equal(
            requestsBeforeResume[0].tools.map(\.name),
            [
                GatewayFlowScratchpadTool.identifier.rawValue,
                Standard.Tools.FindCapabilities.identifier.rawValue,
            ],
            "first turn projects the host-authorized tool surface"
        )
        try Expect.equal(
            requestsBeforeResume[1].tools.map(\.name),
            [
                GatewayFlowScratchpadTool.identifier.rawValue,
                Standard.Tools.FindCapabilities.identifier.rawValue,
            ],
            "host-exposed tool remains visible before approval suspension"
        )

        let resumed = try await executor.resume(
            sessionID: sessionID,
            approvalDecision: .approved
        )
        let requestsAfterResume = await adapter.recordedRequests()
        let values = await store.all()

        try Expect.equal(
            resumed.response?.message.content.text,
            "approved discovery resumed",
            "approval resume reaches final response"
        )
        try Expect.equal(
            values,
            [
                "approved after discovery",
            ],
            "approved host-exposed tool executes exactly once"
        )
        try Expect.equal(
            requestsAfterResume.count,
            3,
            "model loop continues after approval"
        )
        try Expect.equal(
            requestsAfterResume[2].tools.map(\.name),
            [
                GatewayFlowScratchpadTool.identifier.rawValue,
                Standard.Tools.FindCapabilities.identifier.rawValue,
            ],
            "explicit exposure survives approval resume"
        )

        return [
            .field(
                "persisted",
                persistedExposure.joined(separator: ",")
            ),
            .field(
                "after_resume",
                requestsAfterResume[2].tools.map(\.name).joined(separator: ",")
            ),
            .field(
                "executions",
                String(values.count)
            ),
        ]
    }
}
