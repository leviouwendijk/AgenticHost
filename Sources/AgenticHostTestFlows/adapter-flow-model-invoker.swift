import Agentic

/// Test-only bridge for fixtures that deliberately exercise a concrete model
/// adapter while Runtime itself consumes the semantic AgentModelInvoking
/// boundary.
struct AdapterFlowModelInvoker: AgentModelInvoking {
    let adapter: any AgentModelAdapter
    let model: String
    let adapterIdentifier: AgentModelAdapterIdentifier

    init(
        adapter: any AgentModelAdapter,
        model: String,
        adapterIdentifier: AgentModelAdapterIdentifier = "adapter_flow_fixture"
    ) {
        self.adapter = adapter
        self.model = model
        self.adapterIdentifier = adapterIdentifier
    }

    func buffered(
        _ invocation: AgentModelInvocation
    ) async throws -> AgentModelInvocationResult {
        let route = adapterFlowRoute(
            adapterIdentifier: adapterIdentifier,
            model: model,
            purpose: invocation.selection.purpose
        )
        let response = try await adapter.respond(
            request: invocation.request,
            route: route,
            context: invocation.context
        )

        return result(
            response: response,
            invocation: invocation,
            route: route
        )
    }

    func stream(
        _ invocation: AgentModelInvocation
    ) -> AsyncThrowingStream<AgentModelInvocationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let route = adapterFlowRoute(
                        adapterIdentifier: adapterIdentifier,
                        model: model,
                        purpose: invocation.selection.purpose
                    )

                    continuation.yield(
                        .routed(
                            AgentModelRouteResult(
                                route: route
                            )
                        )
                    )

                    for try await event in adapter.respond(
                        request: invocation.request,
                        route: route,
                        delivery: .stream,
                        context: invocation.context
                    ) {
                        switch event {
                        case .completed(let response):
                            continuation.yield(
                                .completed(
                                    result(
                                        response: response,
                                        invocation: invocation,
                                        route: route
                                    )
                                )
                            )

                        default:
                            continuation.yield(
                                .model(event)
                            )
                        }
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

    private func result(
        response: AgentResponse,
        invocation: AgentModelInvocation,
        route: AgentModelRoute
    ) -> AgentModelInvocationResult {
        var requestMetadata = invocation.request.metadata
        requestMetadata.merge(
            invocation.metadata
        ) { _, invocationValue in
            invocationValue
        }

        return AgentModelInvocationResult(
            response: response,
            route: AgentModelRouteRecord(
                route: route,
                diagnostics: [],
                requestMetadata: requestMetadata,
                responseMetadata: response.metadata,
                usage: response.usage
            )
        )
    }
}

func adapterFlowRoute(
    adapterIdentifier: AgentModelAdapterIdentifier = "adapter_flow_fixture",
    model: String,
    purpose: AgentModelRoutePurpose = .executor
) -> AgentModelRoute {
    AgentModelRoute(
        purpose: purpose,
        profile: AgentModelProfile(
            identifier: AgentModelProfileIdentifier(
                "adapter_flow_fixture:\(adapterIdentifier.rawValue):\(model)"
            ),
            adapterIdentifier: adapterIdentifier,
            model: model,
            purposes: [
                purpose,
            ],
            capabilities: [
                .text,
                .tool_use,
                .streaming,
                .structured_output,
                .reasoning,
            ],
            cost: .free,
            latency: .low,
            privacy: .local_private
        )
    )
}
