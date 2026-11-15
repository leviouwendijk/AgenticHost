import Agentic
import Foundation

struct GatewayFlowScriptedModelGateway: AgentModelGateway {
    let identifier: AgentModelGatewayIdentifier
    private let provider: GatewayFlowScriptedModelProvider

    init(
        identifier: AgentModelGatewayIdentifier = "gateway_flow_fixture",
        bufferedResponses: [AgentResponse] = [],
        streamBatches: [[AgentStreamEvent]] = [],
        hold: GatewayFlowHold? = nil
    ) {
        self.identifier = identifier
        self.provider = .init(
            state: .init(
                bufferedResponses: bufferedResponses,
                streamBatches: streamBatches
            ),
            hold: hold
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
    let hold: GatewayFlowHold?

    func buffered(
        request: AgentRequest,
        route _: AgentModelRoute,
        context _: AgentModelInvocationContext
    ) async throws -> AgentResponse {
        let index = await state.record(
            request
        )
        await hold?.wait(request: index)

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

    @discardableResult
    func record(
        _ request: AgentRequest
    ) -> Int {
        requests.append(
            request
        )
        return requests.count
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

/// Holds the buffered response to request number `request` (1-based) until
/// released, so a test can observe state while that model call is in flight.
actor GatewayFlowHold {
    private let request: Int
    private var released = false
    private var reached = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    init(request: Int) {
        self.request = request
    }

    func wait(request index: Int) async {
        guard index == request, !released else { return }
        reached = true
        arrivals.forEach { $0.resume() }
        arrivals.removeAll()
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Returns once the held request has arrived.
    func arrived() async {
        guard !reached else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
