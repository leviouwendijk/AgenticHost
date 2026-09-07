import Agentic
import AgenticApple
import Foundation
import Primitives

struct AdapterFlowFoundationScratchpadLoopAdapter: AgentModelAdapter {
    private let provider: AdapterFlowFoundationScratchpadLoopProvider

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

private struct AdapterFlowFoundationScratchpadLoopProvider: AgentModelResponseProviding {
    let state: AdapterFlowFoundationScratchpadLoopState

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

private actor AdapterFlowFoundationScratchpadLoopState {
    private let apple = AppleFoundationModelAdapter()
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
    ) async throws -> AgentResponse {
        switch requests.count {
        case 1:
            return readResponse()

        case 2:
            return try await writeResponse(
                for: request
            )

        case 3:
            return finalResponse()

        default:
            throw AdapterFlowFoundationScratchpadLoopError.unexpectedTurn(
                requests.count
            )
        }
    }

    func nextStreamBatch(
        for request: AgentRequest
    ) async throws -> [AgentStreamEvent] {
        let response = try await nextBufferedResponse(
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
                throw AdapterFlowFoundationScratchpadLoopError.missingToolCall
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

private extension AdapterFlowFoundationScratchpadLoopState {
    func readResponse() -> AgentResponse {
        let call = AgentToolCall(
            id: "adapter-flow-live-scratchpad-read-1",
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
                "live": "foundationmodels",
                "turn": "read_scratchpad"
            ]
        )
    }

    func writeResponse(
        for request: AgentRequest
    ) async throws -> AgentResponse {
        let readResult = try latestToolResult(
            in: request,
            named: AdapterFlowScratchpadReadTool.identifier.rawValue
        )
        let readOutput = try JSONToolBridge.decode(
            AdapterFlowScratchpadReadOutput.self,
            from: readResult.output
        )
        let generated = try await generateScratchpadNote(
            from: readOutput
        )

        note = generated

        let call = AgentToolCall(
            id: "adapter-flow-live-scratchpad-put-1",
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
                "live": "foundationmodels",
                "turn": "write_model_generated_note"
            ]
        )
    }

    func finalResponse() -> AgentResponse {
        AgentResponse(
            message: .init(
                role: .assistant,
                text: "live scratchpad loop ok"
            ),
            stopReason: .end_turn,
            metadata: [
                "source": "adapterflowtest",
                "live": "foundationmodels",
                "turn": "final"
            ]
        )
    }

    func generateScratchpadNote(
        from readOutput: AdapterFlowScratchpadReadOutput
    ) async throws -> String {
        let scratchpadText = readOutput.values.isEmpty
            ? "The scratchpad is empty."
            : readOutput.values.joined(separator: "\n")

        let response = try await apple.respond(
            request: AgentRequest(
                messages: [
                    .init(
                        role: .system,
                        text: """
                        You generate one short scratchpad note for a test.
                        Return only the note.
                        No Markdown.
                        No quotes.
                        No explanation.
                        Maximum 12 words.
                        Be a little spontaneous.
                        """
                    ),
                    .init(
                        role: .user,
                        text: """
                        Current scratchpad state:
                        \(scratchpadText)

                        Add one new short note of your own.
                        """
                    )
                ]
            )
        )

        let cleaned = cleanedNote(
            response.message.content.text
        )

        guard !cleaned.isEmpty else {
            throw AdapterFlowFoundationScratchpadLoopError.emptyGeneratedNote
        }

        return cleaned
    }

    func cleanedNote(
        _ value: String
    ) -> String {
        var text = value
            .components(
                separatedBy: CharacterSet.newlines
            )
            .map {
                $0.trimmingCharacters(
                    in: CharacterSet.whitespacesAndNewlines
                )
            }
            .filter {
                !$0.isEmpty
            }
            .joined(
                separator: " "
            )
            .trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
            )

        while text.hasPrefix("-") || text.hasPrefix("•") || text.hasPrefix("\"") || text.hasPrefix("'") {
            text.removeFirst()
            text = text.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
            )
        }

        while text.hasSuffix("\"") || text.hasSuffix("'") {
            text.removeLast()
            text = text.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
            )
        }

        return String(
            text.prefix(
                160
            )
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
            throw AdapterFlowFoundationScratchpadLoopError.missingToolResult(
                name
            )
        }

        return result
    }
}

private enum AdapterFlowFoundationScratchpadLoopError: Error, LocalizedError, Sendable {
    case unexpectedTurn(Int)
    case missingToolCall
    case missingToolResult(String)
    case emptyGeneratedNote

    var errorDescription: String? {
        switch self {
        case .unexpectedTurn(let turn):
            return "Unexpected live scratchpad loop model turn \(turn)."

        case .missingToolCall:
            return "Live scratchpad loop response did not contain a tool call."

        case .missingToolResult(let name):
            return "Live scratchpad loop request did not contain a tool result for '\(name)'."

        case .emptyGeneratedNote:
            return "FoundationModels returned an empty scratchpad note."
        }
    }
}
