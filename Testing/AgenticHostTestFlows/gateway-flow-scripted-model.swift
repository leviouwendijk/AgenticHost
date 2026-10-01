import Agentic
import Foundation

struct GatewayFlowScriptedModelGateway: AgentModelGateway {
    let identifier: AgentModelGatewayIdentifier
    private let provider: GatewayFlowScriptedModelProvider

    init(
        identifier: AgentModelGatewayIdentifier = "gateway_flow_fixture",
        bufferedResponses: [AgentResponse] = [],
        streamBatches: [[AgentStreamEvent]] = []
    ) {
        self.identifier = identifier
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

private struct GatewayFlowScriptedModelProvider: AgentModelResponseProviding {
    let state: GatewayFlowScriptedModelState

    func buffered(
        request: AgentRequest,
        route _: AgentModelRoute,
        context _: AgentModelInvocationContext
    ) async throws -> AgentResponse {
        await state.record(
            request
        )

        return try await state.nextBufferedResponse()
    }

    func stream(
        request: AgentRequest,
        route _: AgentModelRoute,
        context _: AgentModelInvocationContext
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

private actor GatewayFlowScriptedModelState {
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
            throw GatewayFlowScriptedModelError.missingBufferedResponse
        }

        return bufferedResponses.removeFirst()
    }

    func nextStreamBatch() throws -> [AgentStreamEvent] {
        guard !streamBatches.isEmpty else {
            throw GatewayFlowScriptedModelError.missingStreamBatch
        }

        return streamBatches.removeFirst()
    }
}

private enum GatewayFlowScriptedModelError: Error, LocalizedError, Sendable {
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
