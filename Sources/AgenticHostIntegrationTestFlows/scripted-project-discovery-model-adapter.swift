import AgenticIO
import Agentic
import Primitives

struct ScriptedProjectDiscoveryModelAdapter: AgentModelAdapter {
    let userFormatterPath: String
    let dogFormatterPath: String
    let trace: ProjectDiscoveryTrace

    var response: AgentModelResponseProviding {
        ScriptedProjectDiscoveryModelResponseProvider(
            userFormatterPath: userFormatterPath,
            dogFormatterPath: dogFormatterPath,
            trace: trace
        )
    }
}

struct ScriptedProjectDiscoveryModelResponseProvider: AgentModelResponseProviding {
    static let envReadToolCallID = "tool-call-discovery-read-env"

    let userFormatterPath: String
    let dogFormatterPath: String
    let trace: ProjectDiscoveryTrace

    func buffered(
        request: AgentRequest
    ) async throws -> AgentResponse {
        let results = toolResults(
            in: request
        )

        await trace.recordToolResults(
            results
        )

        switch results.count {
        case 0:
            return try await toolCallResponse(
                id: "tool-call-discovery-scan",
                name: ScanPathsTool.identifier.rawValue,
                input: JSONToolBridge.encode(
                    ScanPathsToolInput(
                        path: nil,
                        includeFiles: true,
                        includeDirectories: true,
                        recursive: true,
                        includeHidden: true,
                        followSymlinks: false,
                        maxEntries: 80
                    )
                )
            )

        case 1:
            return try await toolCallResponse(
                id: Self.envReadToolCallID,
                name: ReadFileTool.identifier.rawValue,
                input: JSONToolBridge.encode(
                    ReadFileToolInput(
                        path: ProjectDiscoveryTempFixture.envPath,
                        includeLineNumbers: true
                    )
                )
            )

        case 2:
            return try await toolCallResponse(
                id: "tool-call-discovery-read-user-formatter",
                name: ReadFileTool.identifier.rawValue,
                input: JSONToolBridge.encode(
                    ReadFileToolInput(
                        path: userFormatterPath,
                        includeLineNumbers: true
                    )
                )
            )

        case 3:
            return try await toolCallResponse(
                id: "tool-call-discovery-read-dog-formatter",
                name: ReadFileTool.identifier.rawValue,
                input: JSONToolBridge.encode(
                    ReadFileToolInput(
                        path: dogFormatterPath,
                        includeLineNumbers: true
                    )
                )
            )

        case 4:
            return try await toolCallResponse(
                id: "tool-call-discovery-mutate-formatters",
                name: MutateFilesTool.identifier.rawValue,
                input: JSONToolBridge.encode(
                    mutationInput()
                )
            )

        default:
            return .init(
                message: .init(
                    role: .assistant,
                    text: finalMessage(
                        from: results.last
                    )
                ),
                stopReason: .end_turn
            )
        }
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

private extension ScriptedProjectDiscoveryModelResponseProvider {
    func mutationInput() -> MutateFilesToolInput {
        MutateFilesToolInput(
            reason: "Extract duplicated trimming logic discovered through project scan and targeted reads.",
            entries: [
                .init(
                    kind: .edit_text,
                    path: userFormatterPath,
                    operations: [
                        .replace_lines(
                            .init(
                                range: .init(
                                    start: 9,
                                    end: 16
                                ),
                                lines: [
                                    "        let trimmedName = trimString(name)",
                                    "        let trimmedCity = trimString(city)",
                                ]
                            )
                        ),
                        .insert_lines(
                            .init(
                                position: 5,
                                lines: ProjectDiscoveryTempFixture.helperLines
                            )
                        ),
                    ]
                ),
                .init(
                    kind: .edit_text,
                    path: dogFormatterPath,
                    operations: [
                        .replace_lines(
                            .init(
                                range: .init(
                                    start: 9,
                                    end: 16
                                ),
                                lines: [
                                    "        let trimmedName = trimString(name)",
                                    "        let trimmedBreed = trimString(breed)",
                                ]
                            )
                        ),
                        .insert_lines(
                            .init(
                                position: 5,
                                lines: ProjectDiscoveryTempFixture.helperLines
                            )
                        ),
                    ]
                ),
            ]
        )
    }

    func toolCallResponse(
        id: String,
        name: String,
        input: JSONValue
    ) async throws -> AgentResponse {
        await trace.recordToolCall(
            id: id,
            name: name,
            input: input
        )

        let toolCall = AgentToolCall(
            id: id,
            name: name,
            input: input
        )

        return .init(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .tool_call(
                            toolCall
                        ),
                    ]
                )
            ),
            stopReason: .tool_use
        )
    }

    func toolResults(
        in request: AgentRequest
    ) -> [AgentToolResult] {
        request.messages.flatMap { message in
            message.content.blocks.compactMap { block in
                guard case .tool_result(let result) = block else {
                    return nil
                }

                return result
            }
        }
    }

    func finalMessage(
        from toolResult: AgentToolResult?
    ) -> String {
        guard let toolResult else {
            return "Project discovery flow ended without a tool result."
        }

        if toolResult.isError {
            return "Project discovery mutation was denied or failed."
        }

        return "Project discovery completed: scanned the temp project including hidden entries, verified the hidden .env read was rejected, read the selected formatter files, and staged one coherent mutate_files pass."
    }
}
