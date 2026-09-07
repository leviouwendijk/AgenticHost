import Agentic
import Foundation

struct AdapterFlowScriptedModelAdapter: AgentModelAdapter {
    private let provider: AdapterFlowScriptedModelProvider

    init(
        bufferedResponses: [AgentResponse] = [],
        streamBatches: [[AgentStreamEvent]] = []
    ) {
        self.provider = .init(
            state: .init(
                bufferedResponses: bufferedResponses,
                streamBatches: streamBatches
            )
        )
    }

    var response: AgentModelResponseProviding {
        provider
    }

    func recordedRequests() async -> [AgentRequest] {
        await provider.recordedRequests()
    }
}

private struct AdapterFlowScriptedModelProvider: AgentModelResponseProviding {
    let state: AdapterFlowScriptedModelState

    func buffered(
        request: AgentRequest
    ) async throws -> AgentResponse {
        await state.record(
            request
        )

        return try await state.nextBufferedResponse()
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

                    let events = try await state.nextStreamBatch()

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
}

private actor AdapterFlowScriptedModelState {
    private var bufferedResponses: [AgentResponse]
    private var streamBatches: [[AgentStreamEvent]]
    private var requests: [AgentRequest] = []

    init(
        bufferedResponses: [AgentResponse],
        streamBatches: [[AgentStreamEvent]]
    ) {
        self.bufferedResponses = bufferedResponses
        self.streamBatches = streamBatches
    }

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

    func nextBufferedResponse() throws -> AgentResponse {
        guard !bufferedResponses.isEmpty else {
            throw AdapterFlowScriptedModelError.missingBufferedResponse
        }

        return bufferedResponses.removeFirst()
    }

    func nextStreamBatch() throws -> [AgentStreamEvent] {
        guard !streamBatches.isEmpty else {
            throw AdapterFlowScriptedModelError.missingStreamBatch
        }

        return streamBatches.removeFirst()
    }
}

private enum AdapterFlowScriptedModelError: Error, LocalizedError, Sendable {
    case missingBufferedResponse
    case missingStreamBatch

    var errorDescription: String? {
        switch self {
        case .missingBufferedResponse:
            return "Scripted model has no buffered response left."

        case .missingStreamBatch:
            return "Scripted model has no stream batch left."
        }
    }
}
