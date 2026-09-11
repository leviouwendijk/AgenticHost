import Agentic

/// Test-only bridge for fixtures that deliberately exercise a concrete model
/// gateway while Runtime itself consumes the semantic AgentModelInvoking
/// boundary.
struct GatewayFlowModelInvoker: AgentModelInvoking {
    let gateway: any AgentModelGateway
    let model: String
    let gatewayIdentifier: AgentModelGatewayIdentifier

    init(
        gateway: any AgentModelGateway,
        model: String,
        gatewayIdentifier: AgentModelGatewayIdentifier? = nil
    ) {
        self.gateway = gateway
        self.model = model
        self.gatewayIdentifier = gatewayIdentifier ?? gateway.identifier
    }

    func buffered(
        _ invocation: AgentModelInvocation
    ) async throws -> AgentModelInvocationResult {
        let route = gatewayFlowRoute(
            gatewayIdentifier: gatewayIdentifier,
            model: model,
            purpose: invocation.selection.purpose
        )
        let response = try await gateway.respond(
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
                    let route = gatewayFlowRoute(
                        gatewayIdentifier: gatewayIdentifier,
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

                    for try await event in gateway.respond(
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

func gatewayFlowRoute(
    gatewayIdentifier: AgentModelGatewayIdentifier = "gateway_flow_fixture",
    model: String,
    purpose: AgentModelRoutePurpose = .executor
) -> AgentModelRoute {
    AgentModelRoute(
        purpose: purpose,
        profile: AgentModelProfile(
            identifier: AgentModelProfileIdentifier(
                "gateway_flow_fixture:\(gatewayIdentifier.rawValue):\(model)"
            ),
            gatewayIdentifier: gatewayIdentifier,
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
