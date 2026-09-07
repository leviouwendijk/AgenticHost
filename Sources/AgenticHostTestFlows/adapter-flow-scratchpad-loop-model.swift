import Agentic
import Foundation
import Primitives

struct AdapterFlowScratchpadLoopModelAdapter: AgentModelAdapter {
    private let provider: AdapterFlowScratchpadLoopModelProvider

    init() {
        self.provider = .init(
            state: .init()
        )
    }

    var response: AgentModelResponseProviding {
        provider
    }

    func recordedRequests() async -> [AgentRequest] {
        await provider.recordedRequests()
    }

    func generatedNote() async -> String? {
        await provider.generatedNote()
    }
}

private struct AdapterFlowScratchpadLoopModelProvider: AgentModelResponseProviding {
    let state: AdapterFlowScratchpadLoopModelState

    func buffered(
        request: AgentRequest
    ) async throws -> AgentResponse {
        await state.record(
            request
        )

        return try await state.nextBufferedResponse(
            for: request
        )
    }

    func stream(
        request: AgentRequest
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    await state.record(
                        request
                    )

                    let events = try await state.nextStreamBatch(
                        for: request
                    )

                    for event in events {
                        if Task.isCancelled {
                            continuation.finish(
                                throwing: CancellationError()
                            )
                            return
                        }

                        continuation.yield(
                            event
                        )
                    }

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

    func recordedRequests() async -> [AgentRequest] {
        await state.recordedRequests()
    }

    func generatedNote() async -> String? {
        await state.generatedNote()
    }
}

private actor AdapterFlowScratchpadLoopModelState {
    private var requests: [AgentRequest] = []
    private var note: String?

    func record(
        _ request: AgentRequest
    ) {
        requests.append(
            request
        )
    }

    func recordedRequests() -> [AgentRequest] {
        requests
    }

    func generatedNote() -> String? {
        note
    }

    func nextBufferedResponse(
        for request: AgentRequest
    ) throws -> AgentResponse {
        switch requests.count {
        case 1:
            return readResponse()

        case 2:
            return try writeResponse(
                for: request
            )

        case 3:
            return finalResponse()

        default:
            throw AdapterFlowScratchpadLoopModelError.unexpectedTurn(
                requests.count
            )
        }
    }

    func nextStreamBatch(
        for request: AgentRequest
    ) throws -> [AgentStreamEvent] {
        let response = try nextBufferedResponse(
            for: request
        )

        switch response.stopReason {
        case .tool_use:
            guard let call = response.message.content.blocks.compactMap({ block -> AgentToolCall? in
                guard case .tool_call(let call) = block else {
                    return nil
                }

                return call
            }).first else {
                throw AdapterFlowScratchpadLoopModelError.missingToolCall
            }

            return [
                .toolcall(call),
                .completed(response)
            ]

        default:
            return [
                .completed(response)
            ]
        }
    }
}

private extension AdapterFlowScratchpadLoopModelState {
    func readResponse() -> AgentResponse {
        let call = AgentToolCall(
            id: "adapter-flow-scratchpad-read-1",
            name: AdapterFlowScratchpadReadTool.identifier.rawValue,
            input: .object([:])
        )

        return AgentResponse(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .tool_call(call)
                    ]
                )
            ),
            stopReason: .tool_use,
            metadata: [
                "source": "adapterflowtest",
                "mock_turn": "read_scratchpad"
            ]
        )
    }

    func writeResponse(
        for request: AgentRequest
    ) throws -> AgentResponse {
        let readResult = try latestToolResult(
            in: request,
            named: AdapterFlowScratchpadReadTool.identifier.rawValue
        )
        let readOutput = try JSONToolBridge.decode(
            AdapterFlowScratchpadReadOutput.self,
            from: readResult.output
        )
        let generated = "model note after reading \(readOutput.count) notes"
        note = generated

        let call = AgentToolCall(
            id: "adapter-flow-scratchpad-put-1",
            name: AdapterFlowScratchpadTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                AdapterFlowScratchpadPutInput(
                    text: generated
                )
            )
        )

        return AgentResponse(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .tool_call(call)
                    ]
                )
            ),
            stopReason: .tool_use,
            metadata: [
                "source": "adapterflowtest",
                "mock_turn": "write_generated_note"
            ]
        )
    }

    func finalResponse() -> AgentResponse {
        AgentResponse(
            message: .init(
                role: .assistant,
                text: "scratchpad loop ok"
            ),
            stopReason: .end_turn,
            metadata: [
                "source": "adapterflowtest",
                "mock_turn": "final"
            ]
        )
    }

    func latestToolResult(
        in request: AgentRequest,
        named name: String
    ) throws -> AgentToolResult {
        guard let result = request.messages
            .flatMap(\.content.blocks)
            .compactMap({ block -> AgentToolResult? in
                guard case .tool_result(let result) = block else {
                    return nil
                }

                return result
            })
            .last(where: { result in
                result.name == name
            })
        else {
            throw AdapterFlowScratchpadLoopModelError.missingToolResult(
                name
            )
        }

        return result
    }
}

private enum AdapterFlowScratchpadLoopModelError: Error, LocalizedError, Sendable {
    case unexpectedTurn(Int)
    case missingToolCall
    case missingToolResult(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedTurn(let turn):
            return "Unexpected scratchpad loop model turn \(turn)."

        case .missingToolCall:
            return "Scratchpad loop response did not contain a tool call."

        case .missingToolResult(let name):
            return "Scratchpad loop request did not contain a tool result for '\(name)'."
        }
    }
}
