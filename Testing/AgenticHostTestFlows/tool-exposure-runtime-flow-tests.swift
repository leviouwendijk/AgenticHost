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
        let hiddenCall = ToolCall(
            id: "runtime-hidden-tool-call",
            tool: GatewayFlowScratchpadTool.identifier,
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
                        .tool_call(
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
                    .toolcall(
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
        let runner = AgentRunner(
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

        _ = try await runner.run(
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
            .compactMap { block -> ToolResult? in
                guard case .tool_result(let result) = block else {
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

    static func runSkillSeededDiscovery() async throws -> [TestDiagnostic] {
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
        let runner = AgentRunner(
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

        _ = try await runner.run(
            AgentRequest(
                messages: [
                    .init(
                        role: .user,
                        text: "Inspect the seeded tool surface."
                    ),
                ]
            ),
            sessionID: "runtime-tool-exposure-skill-seed"
        )

        let requests = await adapter.recordedRequests()
        let advertised = try Expect.notNil(
            requests.first,
            "skill-seeded request"
        ).tools.map(
            \.name
        )

        try Expect.equal(
            advertised,
            [
                GatewayFlowEchoTool.identifier.rawValue,
                Standard.Tools.FindCapabilities.identifier.rawValue,
            ],
            "skill-seeded discovery exposes skill tools plus find_tools"
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
        let findCall = ToolCall(
            id: "runtime-resume-find-tools",
            tool: Standard.Tools.FindCapabilities.identifier,
            input: .object([
                "arguments": try JSONValue.encoding(
                    Standard.Tools.FindCapabilities.Input(
                        query: GatewayFlowScratchpadTool.identifier.rawValue,
                        maximumResults: 1
                    )
                ),
            ])
        )
        let mutateCall = ToolCall(
            id: "runtime-resume-scratchpad-put",
            tool: GatewayFlowScratchpadTool.identifier,
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
                        .tool_call(
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
                        .tool_call(
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
                    .toolcall(
                        findCall
                    ),
                    .completed(
                        findResponse
                    ),
                ],
                [
                    .toolcall(
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
                    Standard.Tools.FindCapabilities.identifier,
                ]
            )
        )
        let runner = AgentRunner(
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
                }
            ),
            capabilityState: capabilityState,
            recording: .init(
                historyStore: historyStore
            )
        )

        let initialResult = try await runner.run(
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
            "discovered bounded mutation suspends for approval"
        )

        try Expect.equal(
            pendingApproval.toolCall.tool.rawValue,
            GatewayFlowScratchpadTool.identifier.rawValue,
            "approval belongs to the discovered tool"
        )
        try Expect.isEmpty(
            await store.all(),
            "discovered mutation has not executed before approval"
        )

        let checkpoint = try Expect.notNil(
            try await historyStore.loadCheckpoint(
                sessionID: sessionID
            ),
            "persisted discovery checkpoint"
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
            "checkpoint persists activated discovery surface"
        )

        let requestsBeforeResume = await adapter.recordedRequests()

        try Expect.equal(
            requestsBeforeResume.count,
            2,
            "discovery and mutation proposal occur before suspension"
        )
        try Expect.equal(
            requestsBeforeResume[0].tools.map(\.name),
            [
                Standard.Tools.FindCapabilities.identifier.rawValue,
            ],
            "first turn is discovery only"
        )
        try Expect.equal(
            requestsBeforeResume[1].tools.map(\.name),
            [
                GatewayFlowScratchpadTool.identifier.rawValue,
                Standard.Tools.FindCapabilities.identifier.rawValue,
            ],
            "discovered tool is exposed before approval suspension"
        )

        let resumed = try await runner.resume(
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
            "approved discovered tool executes exactly once"
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
            "discovered exposure survives approval resume"
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
