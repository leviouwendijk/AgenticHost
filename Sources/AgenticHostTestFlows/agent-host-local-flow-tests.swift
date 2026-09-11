import Agentic
import AgenticExecution
import AgenticHost
import AgenticIO
import AgenticModels
import AgenticRuntime
import Foundation
import TestFlows

private struct AgentHostLocalProfileProvider:
    AgentModelProfileProvider
{
    let gatewayIdentifier: AgentModelGatewayIdentifier

    func profiles() throws -> [AgentModelProfile] {
        [
            .init(
                identifier: "agent-host-local-scripted",
                gatewayIdentifier: gatewayIdentifier,
                model: "scripted",
                title: "Agent Host Local Scripted",
                capabilities: [
                    .text,
                ],
                cost: .free,
                latency: .low,
                privacy: .local_private
            ),
        ]
    }
}

private struct AgentHostLocalModelProvider:
    AgentModelProvider
{
    let modelGateway: GatewayFlowScriptedModelGateway

    let descriptor = AgentModelProviderDescriptor(
        source: "agent-host-local-scripted",
        displayName: "Agent Host Local Scripted"
    )

    var gateways: [AgentModelGatewayFactory] {
        [
            .init(
                identifier: modelGateway.identifier
            ) {
                modelGateway
            },
        ]
    }

    var profileProviders: [any AgentModelProfileProvider] {
        [
            AgentHostLocalProfileProvider(
                gatewayIdentifier: modelGateway.identifier
            ),
        ]
    }
}

private struct AgentHostLocalSelectionProfileProvider:
    AgentModelProfileProvider
{
    func profiles() throws -> [AgentModelProfile] {
        [
            .init(
                identifier: "agent-host-local-preferred",
                gatewayIdentifier: "agent-host-local-selection",
                model: "preferred",
                title: "Agent Host Local Preferred",
                capabilities: [
                    .text,
                ],
                cost: .free,
                latency: .low,
                privacy: .local_private
            ),
            .init(
                identifier: "agent-host-local-eligible",
                gatewayIdentifier: "agent-host-local-selection",
                model: "eligible",
                title: "Agent Host Local Eligible",
                capabilities: [
                    .text,
                ],
                cost: .free,
                latency: .low,
                privacy: .local_private
            ),
        ]
    }
}

private struct AgentHostLocalSelectionModelProvider:
    AgentModelProvider
{
    let descriptor = AgentModelProviderDescriptor(
        source: "agent-host-local-selection",
        displayName: "Agent Host Local Selection"
    )

    var gateways: [AgentModelGatewayFactory] {
        [
            .init(
                identifier: "agent-host-local-selection"
            ) {
                AgentHostLocalSelectionModelGateway()
            },
        ]
    }

    var profileProviders: [any AgentModelProfileProvider] {
        [
            AgentHostLocalSelectionProfileProvider(),
        ]
    }
}

private struct AgentHostLocalSelectionModelGateway:
    AgentModelGateway
{
    let identifier: AgentModelGatewayIdentifier = "agent-host-local-selection"

    var response: AgentModelResponseProviding {
        AgentHostLocalSelectionResponseProvider()
    }
}

private struct AgentHostLocalSelectionResponseProvider:
    AgentModelResponseProviding
{
    func buffered(
        request: AgentRequest,
        route: AgentModelRoute,
        context _: AgentModelInvocationContext
    ) async throws -> AgentResponse {
        AgentResponse(
            message: .init(
                role: .assistant,
                text: "semantic selection ok"
            ),
            stopReason: .end_turn,
            metadata: [
                "routed_profile_id": route.profile.identifier.rawValue,
                "routed_model": route.profile.model,
                "preferred_profile_id":
                    request.metadata["preferred_model_profile_id"]
                    ?? "<nil>",
            ]
        )
    }

    func stream(
        request _: AgentRequest,
        route _: AgentModelRoute,
        context _: AgentModelInvocationContext
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private actor AgentHostLocalApprovalProbe {
    private var invocationCount = 0

    func recordInvocation() {
        invocationCount += 1
    }

    func count() -> Int {
        invocationCount
    }
}

private struct AgentHostLocalApprovalTool: AgentTool {
    typealias Input = GatewayFlowEchoToolInput
    typealias Output = GatewayFlowEchoToolOutput

    static let identifier: AgentToolIdentifier = "agent_host_local_approval_tool"
    static let description = "Bounded mutation fixture for AgentHost.Local typed resume."
    static let risk: ActionRisk = .boundedmutate

    let probe: AgentHostLocalApprovalProbe

    var identifier: AgentToolIdentifier {
        Self.identifier
    }

    var description: String {
        Self.description
    }

    var risk: ActionRisk {
        Self.risk
    }

    func preflight(
        _ input: Input,
        context: AgentToolExecutionContext
    ) async throws -> ToolPreflight {
        _ = input

        return ToolPreflight(
            toolName: identifier.rawValue,
            risk: risk,
            workspaceRoot: context.workspace?.rootURL.path,
            summary: description
        )
    }

    func call(
        _ input: Input,
        context _: AgentToolExecutionContext
    ) async throws -> Output {
        await probe.recordInvocation()

        return .init(
            text: input.text
        )
    }
}

enum AgentHostLocalFlowTesting {
    static func runService() async throws -> [TestFlowDiagnostic] {
        let adapter = GatewayFlowScriptedModelGateway(
            bufferedResponses: [
                AgentResponse(
                    message: .init(
                        role: .assistant,
                        text: "local service ok"
                    ),
                    stopReason: .end_turn
                ),
            ]
        )
        let application = Agentic.application(
            "agent-host-local-service-fixture"
        ) {
            modelProvider(
                AgentHostLocalModelProvider(
                    modelGateway: adapter
                )
            )
        }
        let runtime = try await AgenticRuntime(
            application: application
        )
        let host = AgentHost.Local(
            runtime: runtime
        )
        let sessionID: AgentHost.Session.ID = "agent-host-local-service"
        let started = try await host.start(
            .init(
                id: sessionID,
                title: "Local service",
                metadata: [
                    "fixture": "service",
                ]
            )
        )
        let eventStream = host.observe(
            sessionID
        )
        let firstEvent = Task<AgentRunEvent?, Error> {
            for try await event in eventStream {
                return event
            }

            return nil
        }
        let stateStream = host.observeState(
            sessionID
        )
        let firstState = Task<AgentRunStateSnapshot?, Error> {
            for try await state in stateStream {
                return state
            }

            return nil
        }
        let result = try await host.submit(
            .init(
                session: sessionID,
                prompt: "Return the scripted local response.",
                execution: .init(
                    modelSelection: .init(
                        purpose: .executor,
                        preferences: .init(
                            preferredProfileIdentifier: "agent-host-local-scripted"
                        )
                    ),
                    system: "Local service system.",
                    configuration: .init(
                        maximumIterations: 4,
                        autonomyMode: .auto_observe
                    )
                ),
                metadata: [
                    "turn": "1",
                ]
            )
        )
        let observedEvent = try await firstEvent.value
        let observedState = try await firstState.value
        let requests = await adapter.recordedRequests()
        let sessions = try await host.sessions()
        let capabilities = try await host.capabilities()
        let transcript = try await host.transcript(
            sessionID
        )

        guard started.id == sessionID,
              started.title == "Local service",
              sessions.count == 1,
              sessions.first?.interaction == nil,
              capabilities.models.map(\.id.rawValue) == [
                "agent-host-local-scripted",
              ],
              !capabilities.tools.modelFacingIdentifiers.isEmpty,
              result.isCompleted,
              result.response?.message.content.text == "local service ok",
              observedEvent != nil,
              observedState?.sessionID == result.sessionID,
              requests.count == 1,
              requests.first?.metadata["preferred_model_profile_id"] == "agent-host-local-scripted",
              requests.first?.messages.first?.role == .system,
              requests.first?.messages.first?.content.text == "Local service system.",
              transcript.session == sessionID,
              transcript.messages.first?.role == .user,
              transcript.messages.first?.content.text == "Return the scripted local response.",
              transcript.messages.last?.role == .assistant,
              transcript.messages.last?.content.text == "local service ok"
        else {
            throw AgentHostLocalFlowError.invalidServiceLifecycle
        }

        return [
            .field(
                "session",
                sessionID.rawValue
            ),
            .field(
                "models",
                String(capabilities.models.count)
            ),
            .field(
                "runtime_states",
                observedState == nil ? "0" : "1"
            ),
            .field(
                "transcript_messages",
                String(transcript.messages.count)
            ),
        ]
    }

    static func runSemanticModelSelection() async throws -> [TestFlowDiagnostic] {
        let application = Agentic.application(
            "agent-host-local-model-selection-fixture"
        ) {
            modelProvider(
                AgentHostLocalSelectionModelProvider()
            )
        }
        let runtime = try await AgenticRuntime(
            application: application
        )
        let host = AgentHost.Local(
            runtime: runtime
        )
        let sessionID: AgentHost.Session.ID =
            "agent-host-local-model-selection"

        _ = try await host.start(
            .init(
                id: sessionID
            )
        )

        let result = try await host.submit(
            .init(
                session: sessionID,
                prompt: "Resolve the semantic model selection.",
                execution: .init(
                    modelSelection: .init(
                        purpose: .executor,
                        preferences: .init(
                            preferredProfileIdentifier:
                                "agent-host-local-preferred"
                        ),
                        constraints: .init(
                            allowedProfileIdentifiers: [
                                "agent-host-local-eligible",
                            ]
                        )
                    ),
                    configuration: .init(
                        maximumIterations: 1,
                        autonomyMode: .auto_observe,
                        responseDelivery: .buffered
                    )
                )
            )
        )

        guard result.isCompleted,
              result.response?.message.content.text
                == "semantic selection ok",
              result.response?.metadata["routed_profile_id"]
                == "agent-host-local-eligible",
              result.response?.metadata["routed_model"]
                == "eligible",
              result.response?.metadata["preferred_profile_id"]
                == "agent-host-local-preferred"
        else {
            throw AgentHostLocalFlowError.invalidSemanticModelSelection
        }

        return [
            .field(
                "preferred_profile",
                "agent-host-local-preferred"
            ),
            .field(
                "allowed_profile",
                "agent-host-local-eligible"
            ),
            .field(
                "routed_profile",
                result.response?.metadata["routed_profile_id"]
                    ?? "<nil>"
            ),
        ]
    }

    static func runApprovalResume() async throws -> [TestFlowDiagnostic] {
        let probe = AgentHostLocalApprovalProbe()
        let toolCall = AgentToolCall(
            id: "agent-host-local-approval-call",
            name: AgentHostLocalApprovalTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                GatewayFlowEchoToolInput(
                    text: "approved payload"
                )
            )
        )
        let adapter = GatewayFlowScriptedModelGateway(
            bufferedResponses: [
                AgentResponse(
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
                ),
                AgentResponse(
                    message: .init(
                        role: .assistant,
                        text: "local approval ok"
                    ),
                    stopReason: .end_turn
                ),
            ]
        )
        let application = Agentic.application(
            "agent-host-local-approval-fixture"
        ) {
            tools {
                AgentHostLocalApprovalTool(
                    probe: probe
                )
            }
            modelProvider(
                AgentHostLocalModelProvider(
                    modelGateway: adapter
                )
            )
        }
        let runtime = try await AgenticRuntime(
            application: application
        )
        let host = AgentHost.Local(
            runtime: runtime
        )
        let sessionID: AgentHost.Session.ID = "agent-host-local-approval"
        _ = try await host.start(
            .init(
                id: sessionID
            )
        )

        let suspended = try await host.submit(
            .init(
                session: sessionID,
                prompt: "Invoke the approval tool."
            )
        )
        guard suspended.isAwaitingApproval,
              let request = suspended.interactionRequest,
              request.kind == .approval
        else {
            throw AgentHostLocalFlowError.missingApprovalSuspension
        }

        let suspendedSessions = try await host.sessions()
        guard suspendedSessions.first?.interaction?.id == request.id else {
            throw AgentHostLocalFlowError.missingSessionInteraction
        }

        let resumed = try await host.resume(
            .init(
                request: request,
                resolution: .approval(
                    .approved
                ),
                metadata: [
                    "fixture": "agent-host-local",
                ]
            )
        )
        let invocationCount = await probe.count()
        let completedSessions = try await host.sessions()
        let transcript = try await host.transcript(
            sessionID
        )

        guard resumed.isCompleted,
              resumed.response?.message.content.text == "local approval ok",
              invocationCount == 1,
              completedSessions.first?.interaction == nil,
              transcript.messages.last?.content.text == "local approval ok"
        else {
            throw AgentHostLocalFlowError.invalidApprovalResume
        }

        return [
            .field(
                "runtime_run",
                resumed.sessionID
            ),
            .field(
                "tool_invocations",
                String(invocationCount)
            ),
        ]
    }
}

private enum AgentHostLocalFlowError: Error {
    case invalidServiceLifecycle
    case invalidSemanticModelSelection
    case missingApprovalSuspension
    case missingSessionInteraction
    case invalidApprovalResume
}
