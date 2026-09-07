import AgenticIO
import Agentic

struct ScriptedMutateWriteModelAdapter: AgentModelAdapter {
    let path: String
    let middleLines: [String]

    var response: AgentModelResponseProviding {
        ScriptedMutateWriteModelResponseProvider(
            path: path,
            middleLines: middleLines
        )
    }
}

struct ScriptedMutateWriteModelResponseProvider: AgentModelResponseProviding {
    let path: String
    let middleLines: [String]

    func buffered(
        request: AgentRequest
    ) async throws -> AgentResponse {
        if let toolResult = latestToolResult(
            in: request
        ) {
            return .init(
                message: .init(
                    role: .assistant,
                    text: finalMessage(
                        from: toolResult
                    )
                ),
                stopReason: .end_turn
            )
        }

        let toolCall = AgentToolCall(
            id: "tool-call-mutate-apple-fragment",
            name: MutateFilesTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                MutateFilesToolInput(
                    reason: "Replace only the Apple-generated middle fragment.",
                    entries: [
                        .init(
                            kind: .edit_text,
                            path: path,
                            operations: [
                                .replace_lines(
                                    .init(
                                        range: .init(
                                            start: 7,
                                            end: 13
                                        ),
                                        lines: middleLines
                                    )
                                )
                            ]
                        )
                    ]
                )
            )
        )

        return .init(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .tool_call(
                            toolCall
                        )
                    ]
                )
            ),
            stopReason: .tool_use
        )
    }

    func stream(
        request: AgentRequest
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await buffered(
                        request: request
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

private extension ScriptedMutateWriteModelResponseProvider {
    func latestToolResult(
        in request: AgentRequest
    ) -> AgentToolResult? {
        for message in request.messages.reversed() {
            for block in message.content.blocks.reversed() {
                guard case .tool_result(let result) = block else {
                    continue
                }

                return result
            }
        }

        return nil
    }

    func finalMessage(
        from toolResult: AgentToolResult
    ) -> String {
        if toolResult.isError {
            return "mutate_files was denied or failed."
        }

        return "mutate_files completed through AgenticInterfaces approval."
    }
}
