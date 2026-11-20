import Agentic
import AgenticRuntime
import Foundation

enum AgentInteractionContractFlowTesting {
    static func run() async throws {
        let suspension = Run.Suspension.user_input(
            try UserInputRequest(
                prompt: "Choose a direction.",
                input: .single_choice(
                    .init(
                        choices: [
                            .init(
                                id: "continue",
                                label: "Continue",
                                value: "continue"
                            ),
                            .init(
                                id: "stop",
                                label: "Stop",
                                value: "stop"
                            ),
                        ]
                    )
                ),
                metadata: [
                    "origin": "interaction-contract-flow",
                ]
            )
        )

        let request = Run.Interaction.Request(
            sessionID: "interaction-contract-session",
            suspension: suspension
        )

        guard request.id == suspension.id,
              request.kind == .user_input,
              request.requirement.pendingUserInput != nil
        else {
            throw AgentInteractionContractFlowError.invalidRequestProjection
        }

        let provider = ScriptedAgentInteractionProvider(
            resolution: .user_input(
                .single_choice(
                    .choice(
                        "continue"
                    )
                )
            )
        )

        let response = try await provider.resolve(
            request
        )

        guard response.requestID == request.id,
              response.sessionID == request.sessionID,
              response.kind == request.kind
        else {
            throw AgentInteractionContractFlowError.invalidResponseProjection
        }

        let encoded = try JSONEncoder().encode(
            response
        )
        let decoded = try JSONDecoder().decode(
            Run.Interaction.Response.self,
            from: encoded
        )

        guard decoded == response else {
            throw AgentInteractionContractFlowError.roundTripMismatch
        }
    }
}

private struct ScriptedAgentInteractionProvider:
    AgentInteractionProviding
{
    let resolution: Run.Interaction.Resolution

    func resolve(
        _ request: Run.Interaction.Request
    ) async throws -> Run.Interaction.Response {
        .init(
            request: request,
            resolution: resolution,
            metadata: [
                "provider": "scripted",
            ]
        )
    }
}

private enum AgentInteractionContractFlowError:
    Error
{
    case invalidRequestProjection
    case invalidResponseProjection
    case roundTripMismatch
}
