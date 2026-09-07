import Agentic
import AgenticApple
import AgenticExecution
import AgenticRuntime
import Foundation
import Primitives
import TestFlows

#if canImport(FoundationModels)
import FoundationModels
#endif

enum AgenticRuntimeAdapterFlowTesting {

    static func runAdapterStreamSupported() async throws -> [TestFlowDiagnostic] {
        let request = AgentRequest(
            model: "scripted",
            messages: [
                .init(
                    role: .user,
                    text: "Stream a tiny response."
                )
            ]
        )
        let response = AgentResponse(
            message: .init(
                role: .assistant,
                text: "stream ok"
            ),
            stopReason: .end_turn,
            metadata: [
                "source": "adapterflowtest"
            ]
        )
        let adapter = AdapterFlowScriptedModelAdapter(
            streamBatches: [
                [
                    .messagedelta(
                        .text("stream ")
                    ),
                    .messagedelta(
                        .text("ok")
                    ),
                    .completed(response),
                ]
            ]
        )

        var events: [AgentStreamEvent] = []

        for try await event in adapter.respond(
            request: request,
            delivery: .stream
        ) {
            events.append(
                event
            )
        }

        let text = streamText(
            from: events
        )

        try Expect.equal(
            text,
            "stream ok",
            "stream text"
        )

        return [
            AdapterRuntimeFlowDiagnostics.input(
                request
            ),
            AdapterRuntimeFlowDiagnostics.stream(
                events
            ),
            AdapterRuntimeFlowDiagnostics.output(
                response
            )
        ]
    }

    static func runAdapterToolLoop() async throws -> [TestFlowDiagnostic] {
        let toolCall = AgentToolCall(
            id: "adapter-flow-tool-call-1",
            name: AdapterFlowEchoTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                AdapterFlowEchoToolInput(
                    text: "tool payload"
                )
            )
        )
        let request = AgentRequest(
            model: "scripted",
            messages: [
                .init(
                    role: .user,
                    text: "Use the echo tool, then answer with 'tool use ok'."
                )
            ]
        )
        let firstResponse = AgentResponse(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .text("need tool "),
                        .tool_call(toolCall)
                    ]
                )
            ),
            stopReason: .tool_use,
            metadata: [
                "source": "adapterflowtest"
            ]
        )
        let finalResponse = AgentResponse(
            message: .init(
                role: .assistant,
                text: "tool use ok"
            ),
            stopReason: .end_turn,
            metadata: [
                "source": "adapterflowtest"
            ]
        )
        let adapter = AdapterFlowScriptedModelAdapter(
            streamBatches: [
                [
                    .messagedelta(
                        .text("need tool ")
                    ),
                    .toolcall(toolCall),
                    .completed(firstResponse),
                ],
                [
                    .completed(finalResponse)
                ]
            ]
        )
        let runner = AgentRunner(
            adapter: adapter,
            configuration: .init(
                maximumIterations: 2,
                responseDelivery: .stream
            ),
            toolRegistry: try ToolRegistry {
                AdapterFlowEchoTool()
            }
        )

        let result = try await runner.run(
            request,
            sessionID: "adapter-flow-tool-loop"
        )

        try Expect.equal(
            result.response?.message.content.text,
            "tool use ok",
            "tool loop final response"
        )

        try Expect.containsOrdered(
            result.events.map(\.kind),
            [
                .model_stream_started,
                .model_stream_tool_call,
                .model_stream_completed,
                .assistant_response,
                .tool_preflight,
                .tool_approved,
                .tool_result,
                .model_stream_started,
                .model_stream_completed,
                .assistant_response
            ],
            "tool loop events"
        )

        let recordedRequests = await adapter.recordedRequests()

        return [
            AdapterRuntimeFlowDiagnostics.input(
                request
            ),
            .field(
                "model_calls",
                String(
                    recordedRequests.count
                )
            ),
            AdapterRuntimeFlowDiagnostics.events(
                result.events
            ),
            AdapterRuntimeFlowDiagnostics.output(
                finalResponse
            )
        ]
    }

    static func runAdapterScratchpadTool() async throws -> [TestFlowDiagnostic] {
        let store = AdapterFlowScratchpadStore()
        let tool = AdapterFlowScratchpadTool(
            store: store
        )
        let note = "safe in-memory note"
        let toolCall = AgentToolCall(
            id: "adapter-flow-scratchpad-call-1",
            name: AdapterFlowScratchpadTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                AdapterFlowScratchpadPutInput(
                    text: note
                )
            )
        )
        let request = AgentRequest(
            model: "scripted",
            messages: [
                .init(
                    role: .user,
                    text: "Store a scratchpad note, then answer with 'scratchpad ok'."
                )
            ]
        )
        let firstResponse = AgentResponse(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .tool_call(toolCall)
                    ]
                )
            ),
            stopReason: .tool_use,
            metadata: [
                "source": "adapterflowtest"
            ]
        )
        let finalResponse = AgentResponse(
            message: .init(
                role: .assistant,
                text: "scratchpad ok"
            ),
            stopReason: .end_turn,
            metadata: [
                "source": "adapterflowtest"
            ]
        )
        let adapter = AdapterFlowScriptedModelAdapter(
            streamBatches: [
                [
                    .toolcall(toolCall),
                    .completed(firstResponse),
                ],
                [
                    .completed(finalResponse)
                ]
            ]
        )
        let runner = AgentRunner(
            adapter: adapter,
            configuration: .init(
                maximumIterations: 2,
                autonomyMode: .auto_bounded_mutate,
                responseDelivery: .stream
            ),
            toolRegistry: try ToolRegistry {
                tool
            }
        )

        let result = try await runner.run(
            request,
            sessionID: "adapter-flow-scratchpad-tool"
        )
        let scratchpadValues = await store.all()
        let recordedRequests = await adapter.recordedRequests()
        let secondRequest = try Expect.notNil(
            recordedRequests.count > 1 ? recordedRequests[1] : nil,
            "second model request"
        )
        let toolResults = secondRequest.messages
            .flatMap(\.content.blocks)
            .compactMap { block -> AgentToolResult? in
                guard case .tool_result(let result) = block else {
                    return nil
                }

                return result
            }

        try Expect.equal(
            result.response?.message.content.text,
            "scratchpad ok",
            "scratchpad final response"
        )
        try Expect.equal(
            scratchpadValues,
            [note],
            "scratchpad values"
        )
        try Expect.equal(
            toolResults.count,
            1,
            "tool result count"
        )

        let toolResult = try Expect.notNil(
            toolResults.first,
            "tool result"
        )

        try Expect.equal(
            toolResult.name,
            AdapterFlowScratchpadTool.identifier.rawValue,
            "tool result name"
        )
        try Expect.contains(
            String(
                describing: toolResult.output
            ),
            note,
            "tool result output"
        )
        try Expect.containsOrdered(
            result.events.map(\.kind),
            [
                .model_stream_started,
                .model_stream_tool_call,
                .model_stream_completed,
                .assistant_response,
                .tool_preflight,
                .tool_approved,
                .tool_result,
                .model_stream_started,
                .model_stream_completed,
                .assistant_response
            ],
            "scratchpad tool events"
        )

        return [
            AdapterRuntimeFlowDiagnostics.input(
                request
            ),
            .field(
                "model_calls",
                String(
                    recordedRequests.count
                )
            ),
            .section(
                "scratchpad",
                scratchpadValues
            ),
            .section(
                "tool_result_to_model",
                [
                    "name: \(toolResult.name ?? "<nil>")",
                    "output: \(toolResult.output)"
                ]
            ),
            AdapterRuntimeFlowDiagnostics.events(
                result.events
            ),
            AdapterRuntimeFlowDiagnostics.output(
                finalResponse
            )
        ]
    }

    static func runAdapterScratchpadReadWriteLoop() async throws -> [TestFlowDiagnostic] {
        let store = AdapterFlowScratchpadStore()
        let readTool = AdapterFlowScratchpadReadTool(
            store: store
        )
        let putTool = AdapterFlowScratchpadTool(
            store: store
        )
        let initialScratchpadValues = await store.all()

        try Expect.isEmpty(
            initialScratchpadValues,
            "fresh scratchpad"
        )

        let adapter = AdapterFlowScratchpadLoopModelAdapter()
        let request = AgentRequest(
            model: "reactive-scratchpad",
            messages: [
                .init(
                    role: .user,
                    text: "Read the scratchpad, add one short note of your own, then answer."
                )
            ]
        )
        let runner = AgentRunner(
            adapter: adapter,
            configuration: .init(
                maximumIterations: 4,
                autonomyMode: .auto_bounded_mutate,
                responseDelivery: .stream
            ),
            toolRegistry: try ToolRegistry {
                readTool
                putTool
            }
        )

        let result = try await runner.run(
            request,
            sessionID: "adapter-flow-scratchpad-read-write-loop"
        )
        let generatedNote = try Expect.notNil(
            await adapter.generatedNote(),
            "generated note"
        )
        let scratchpadValues = await store.all()
        let recordedRequests = await adapter.recordedRequests()

        try Expect.equal(
            result.response?.message.content.text,
            "scratchpad loop ok",
            "scratchpad loop final response"
        )
        try Expect.equal(
            recordedRequests.count,
            3,
            "model call count"
        )
        try Expect.equal(
            scratchpadValues,
            [
                generatedNote
            ],
            "scratchpad loop values"
        )
        try Expect.notEqual(
            generatedNote,
            "safe in-memory note",
            "generated note is not the deterministic fixture note"
        )
        try Expect.contains(
            generatedNote,
            "model note after reading",
            "generated note source"
        )

        let secondRequest = try Expect.notNil(
            recordedRequests.count > 1 ? recordedRequests[1] : nil,
            "second model request"
        )
        let thirdRequest = try Expect.notNil(
            recordedRequests.count > 2 ? recordedRequests[2] : nil,
            "third model request"
        )
        let readResults = toolResults(
            from: secondRequest,
            named: AdapterFlowScratchpadReadTool.identifier.rawValue
        )
        let putResults = toolResults(
            from: thirdRequest,
            named: AdapterFlowScratchpadTool.identifier.rawValue
        )

        try Expect.equal(
            readResults.count,
            1,
            "read tool result count"
        )
        try Expect.equal(
            putResults.count,
            1,
            "put tool result count"
        )
        try Expect.contains(
            String(
                describing: putResults[0].output
            ),
            generatedNote,
            "put tool result output"
        )
        try Expect.containsOrdered(
            result.events.map(\.kind),
            [
                .model_stream_started,
                .model_stream_tool_call,
                .model_stream_completed,
                .assistant_response,
                .tool_preflight,
                .tool_approved,
                .tool_result,
                .model_stream_started,
                .model_stream_tool_call,
                .model_stream_completed,
                .assistant_response,
                .tool_preflight,
                .tool_approved,
                .tool_result,
                .model_stream_started,
                .model_stream_completed,
                .assistant_response
            ],
            "scratchpad read/write loop events"
        )

        return [
            AdapterRuntimeFlowDiagnostics.input(
                request
            ),
            .field(
                "model_calls",
                String(
                    recordedRequests.count
                )
            ),
            .section(
                "initial_scratchpad",
                initialScratchpadValues
            ),
            .field(
                "generated_note",
                generatedNote
            ),
            .section(
                "final_scratchpad",
                scratchpadValues
            ),
            .section(
                "tool_results_to_model",
                [
                    "read: \(readResults[0].output)",
                    "put: \(putResults[0].output)"
                ]
            ),
            AdapterRuntimeFlowDiagnostics.events(
                result.events
            ),
            AdapterRuntimeFlowDiagnostics.output(
                try Expect.notNil(
                    result.response,
                    "final response"
                )
            )
        ]
    }

    static func runAppleLiveScratchpadReadWriteLoop() async throws -> [TestFlowDiagnostic] {
        let enabled = ProcessInfo.processInfo.environment["AGENTIC_APPLE_LIVE_TEST"] == "1"

        guard enabled else {
            return [
                .message("skipped: set AGENTIC_APPLE_LIVE_TEST=1 to run the live FoundationModels scratchpad loop")
            ]
        }

        let store = AdapterFlowScratchpadStore()
        let readTool = AdapterFlowScratchpadReadTool(
            store: store
        )
        let putTool = AdapterFlowScratchpadTool(
            store: store
        )
        let initialScratchpadValues = await store.all()

        try Expect.isEmpty(
            initialScratchpadValues,
            "fresh scratchpad"
        )

        let adapter = AdapterFlowFoundationScratchpadLoopAdapter()
        let request = AgentRequest(
            model: "foundationmodels-reactive-scratchpad",
            messages: [
                .init(
                    role: .user,
                    text: "Read the scratchpad, ask FoundationModels for one spontaneous short note, write it, then answer."
                )
            ]
        )
        let runner = AgentRunner(
            adapter: adapter,
            configuration: .init(
                maximumIterations: 4,
                autonomyMode: .auto_bounded_mutate,
                responseDelivery: .stream
            ),
            toolRegistry: try ToolRegistry {
                readTool
                putTool
            }
        )

        let result = try await runner.run(
            request,
            sessionID: "apple-live-scratchpad-read-write-loop"
        )
        let generatedNote = try Expect.notNil(
            await adapter.generatedNote(),
            "generated note"
        )
        let scratchpadValues = await store.all()
        let recordedRequests = await adapter.recordedRequests()

        try Expect.equal(
            result.response?.message.content.text,
            "live scratchpad loop ok",
            "live scratchpad loop final response"
        )
        try Expect.equal(
            recordedRequests.count,
            3,
            "model call count"
        )
        try Expect.equal(
            scratchpadValues,
            [
                generatedNote
            ],
            "scratchpad values"
        )
        try Expect.notEmpty(
            generatedNote,
            "FoundationModels generated note"
        )

        let secondRequest = try Expect.notNil(
            recordedRequests.count > 1 ? recordedRequests[1] : nil,
            "second model request"
        )
        let thirdRequest = try Expect.notNil(
            recordedRequests.count > 2 ? recordedRequests[2] : nil,
            "third model request"
        )
        let readResults = toolResults(
            from: secondRequest,
            named: AdapterFlowScratchpadReadTool.identifier.rawValue
        )
        let putResults = toolResults(
            from: thirdRequest,
            named: AdapterFlowScratchpadTool.identifier.rawValue
        )

        try Expect.equal(
            readResults.count,
            1,
            "read tool result count"
        )
        try Expect.equal(
            putResults.count,
            1,
            "put tool result count"
        )

        let putOutput = try JSONToolBridge.decode(
            AdapterFlowScratchpadPutOutput.self,
            from: putResults[0].output
        )

        try Expect.equal(
            putOutput.text,
            generatedNote,
            "put tool result text"
        )
        try Expect.equal(
            putOutput.count,
            1,
            "put tool result count"
        )
        try Expect.containsOrdered(
            result.events.map(\.kind),
            [
                .model_stream_started,
                .model_stream_tool_call,
                .model_stream_completed,
                .assistant_response,
                .tool_preflight,
                .tool_approved,
                .tool_result,
                .model_stream_started,
                .model_stream_tool_call,
                .model_stream_completed,
                .assistant_response,
                .tool_preflight,
                .tool_approved,
                .tool_result,
                .model_stream_started,
                .model_stream_completed,
                .assistant_response
            ],
            "live scratchpad read/write loop events"
        )

        return [
            AdapterRuntimeFlowDiagnostics.input(
                request
            ),
            .field(
                "model_calls",
                String(
                    recordedRequests.count
                )
            ),
            .section(
                "initial_scratchpad",
                initialScratchpadValues
            ),
            .field(
                "foundationmodels_generated_note",
                generatedNote
            ),
            .section(
                "final_scratchpad",
                scratchpadValues
            ),
            .section(
                "tool_results_to_model",
                [
                    "read: \(readResults[0].output)",
                    "put.text: \(putOutput.text)",
                    "put.count: \(putOutput.count)"
                ]
            ),
            AdapterRuntimeFlowDiagnostics.events(
                result.events
            ),
            AdapterRuntimeFlowDiagnostics.output(
                try Expect.notNil(
                    result.response,
                    "final response"
                )
            )
        ]
    }

    static func runAppleLiveQuery() async throws -> [TestFlowDiagnostic] {
        let enabled = ProcessInfo.processInfo.environment["AGENTIC_APPLE_LIVE_TEST"] == "1"

        guard enabled else {
            return [
                .message("skipped: set AGENTIC_APPLE_LIVE_TEST=1 to run the live FoundationModels query")
            ]
        }

        let adapter = AppleFoundationModelAdapter()
        let runner = AgentRunner(
            adapter: adapter
        )
        let request = AgentRequest(
            messages: [
                .init(
                    role: .system,
                    text: "Answer in one short sentence."
                ),
                .init(
                    role: .user,
                    text: "Say hello from AgenticApple."
                ),
            ]
        )

        let result = try await runner.run(
            request,
            sessionID: "agentic-adapters-live-query"
        )

        guard let response = result.response else {
            throw TestFlowAssertionFailure(
                label: "live query",
                message: "run completed without a response",
                actual: String(
                    describing: result
                ),
                expected: "non-nil response"
            )
        }

        let text = response.message.content.text.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines
        )

        try Expect.notEmpty(
            text,
            "live response text"
        )

        return [
            AdapterRuntimeFlowDiagnostics.input(
                request
            ),
            AdapterRuntimeFlowDiagnostics.output(
                response
            )
        ]
    }

    static func runAppleLiveStreamQuery() async throws -> [TestFlowDiagnostic] {
        let enabled = ProcessInfo.processInfo.environment["AGENTIC_APPLE_LIVE_TEST"] == "1"

        guard enabled else {
            return [
                .message("skipped: set AGENTIC_APPLE_LIVE_TEST=1 to run the live FoundationModels stream query")
            ]
        }

        let adapter = AppleFoundationModelAdapter()
        let request = AgentRequest(
            messages: [
                .init(
                    role: .system,
                    text: "Answer in one short sentence."
                ),
                .init(
                    role: .user,
                    text: "Say hello from the AgenticApple stream."
                ),
            ]
        )
        var events: [AgentStreamEvent] = []

        for try await event in adapter.respond(
            request: request,
            delivery: .stream
        ) {
            events.append(
                event
            )
        }

        let text = streamText(
            from: events
        )

        try Expect.notEmpty(
            text,
            "live stream text"
        )

        return [
            AdapterRuntimeFlowDiagnostics.input(
                request
            ),
            AdapterRuntimeFlowDiagnostics.stream(
                events
            )
        ]
    }
}

private func toolResults(
    from request: AgentRequest,
    named name: String
) -> [AgentToolResult] {
    request.messages
        .flatMap(\.content.blocks)
        .compactMap { block -> AgentToolResult? in
            guard case .tool_result(let result) = block else {
                return nil
            }

            return result
        }
        .filter { result in
            result.name == name
        }
}

private func streamText(
    from events: [AgentStreamEvent]
) -> String {
    events.compactMap { event in
        switch event {
        case .messagedelta(.text(let value)):
            return value

        default:
            return nil
        }
    }.joined()
}
