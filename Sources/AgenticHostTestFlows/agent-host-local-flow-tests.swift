import Agentic
import AgenticExecution
import AgenticHost
import AgenticIO
import AgenticModels
import AgenticRuntime
import AgenticWorkspace
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

private actor AgentHostLocalWorkspaceAccessProbe {
    private var rootIDsByInvocation: [[String]] = []

    func record(
        rootIDs: [String]
    ) {
        rootIDsByInvocation.append(
            rootIDs
        )
    }

    func snapshot() -> [[String]] {
        rootIDsByInvocation
    }
}

private struct AgentHostLocalGrantedApprovalTool: AgentTool {
    typealias Input = GatewayFlowEchoToolInput
    typealias Output = GatewayFlowEchoToolOutput

    static let identifier: AgentToolIdentifier =
        "agent_host_local_granted_approval_tool"
    static let description =
        "Bounded mutation fixture that requires an activated workspace root."
    static let risk: ActionRisk = .boundedmutate

    let probe: AgentHostLocalApprovalProbe
    let requiredRootID: String

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
        context: AgentToolExecutionContext
    ) async throws -> Output {
        let rootIDs = context.workspace?
            .accessController
            .rootIdentifiers
            .map(\.rawValue)
            ?? []

        guard rootIDs.contains(
            requiredRootID
        ) else {
            throw AgentHostLocalWorkspaceAccessFixtureError
                .requiredRootMissing(
                    requiredRootID
                )
        }

        await probe.recordInvocation()

        return .init(
            text: input.text
        )
    }
}

private struct AgentHostLocalWorkspaceProbeTool: AgentTool {
    typealias Input = GatewayFlowEchoToolInput
    typealias Output = GatewayFlowEchoToolOutput

    static let identifier: AgentToolIdentifier =
        "agent_host_local_workspace_probe"
    static let description =
        "Observe the effective workspace roots for one Host turn."
    static let risk: ActionRisk = .observe

    let probe: AgentHostLocalWorkspaceAccessProbe

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
        context: AgentToolExecutionContext
    ) async throws -> Output {
        let rootIDs = context.workspace?
            .accessController
            .rootIdentifiers
            .map(\.rawValue)
            .sorted()
            ?? []

        await probe.record(
            rootIDs: rootIDs
        )

        return .init(
            text: input.text
        )
    }
}

private actor AgentHostLocalPreparedIntentStore:
    PreparedIntentStore
{
    private var intents:
        [PreparedIntentIdentifier: PreparedIntent] = [:]

    func load(
        id: PreparedIntentIdentifier
    ) async throws -> PreparedIntent? {
        intents[id]
    }

    func list() async throws -> [PreparedIntent] {
        Array(
            intents.values
        )
    }

    func save(
        _ intent: PreparedIntent
    ) async throws {
        intents[intent.id] = intent
    }

    func delete(
        id: PreparedIntentIdentifier
    ) async throws {
        intents.removeValue(
            forKey: id
        )
    }
}

private enum AgentHostLocalWorkspaceAccessFixtureError:
    Error
{
    case requiredRootMissing(String)
    case missingSuspension
    case invalidActivatedLease
    case invalidFirstTurn
    case missingWorkspaceProbe
    case turnGrantLeaked(String)
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

    static func runWorkspaceAccessActivation()
        async throws
        -> [TestFlowDiagnostic]
    {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agent-host-local-workspace-access-\(UUID().uuidString)",
                isDirectory: true
            )
        let projectRoot = fixtureRoot.appendingPathComponent(
            "project",
            isDirectory: true
        )
        let externalRoot = fixtureRoot.appendingPathComponent(
            "external",
            isDirectory: true
        )

        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalRoot,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(
                at: fixtureRoot
            )
        }

        let workspace = try AgentWorkspace(
            root: projectRoot
        )
        let grantedRootID = "agent_host_local_turn"
        let approvalProbe = AgentHostLocalApprovalProbe()
        let workspaceProbe = AgentHostLocalWorkspaceAccessProbe()

        let approvalCall = AgentToolCall(
            id: "agent-host-local-workspace-access-approval-call",
            name: AgentHostLocalGrantedApprovalTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                GatewayFlowEchoToolInput(
                    text: "approved with temporary root"
                )
            )
        )
        let workspaceProbeCall = AgentToolCall(
            id: "agent-host-local-workspace-access-probe-call",
            name: AgentHostLocalWorkspaceProbeTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                GatewayFlowEchoToolInput(
                    text: "probe next turn"
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
                                    approvalCall
                                ),
                            ]
                        )
                    ),
                    stopReason: .tool_use
                ),
                AgentResponse(
                    message: .init(
                        role: .assistant,
                        text: "workspace grant turn ok"
                    ),
                    stopReason: .end_turn
                ),
                AgentResponse(
                    message: .init(
                        role: .assistant,
                        content: .init(
                            blocks: [
                                .tool_call(
                                    workspaceProbeCall
                                ),
                            ]
                        )
                    ),
                    stopReason: .tool_use
                ),
                AgentResponse(
                    message: .init(
                        role: .assistant,
                        text: "workspace grant cleanup ok"
                    ),
                    stopReason: .end_turn
                ),
            ]
        )
        let application = Agentic.application(
            "agent-host-local-workspace-access-fixture"
        ) {
            tools {
                AgentHostLocalGrantedApprovalTool(
                    probe: approvalProbe,
                    requiredRootID: grantedRootID
                )
                AgentHostLocalWorkspaceProbeTool(
                    probe: workspaceProbe
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
            runtime: runtime,
            workspace: workspace
        )
        let sessionID: AgentHost.Session.ID =
            "agent-host-local-workspace-access"

        _ = try await host.start(
            .init(
                id: sessionID
            )
        )

        let suspended = try await host.submit(
            .init(
                session: sessionID,
                prompt: "Request approval before using the temporary root."
            )
        )

        guard suspended.isAwaitingApproval,
              let approvalRequest = suspended.interactionRequest,
              approvalRequest.kind == .approval
        else {
            throw AgentHostLocalWorkspaceAccessFixtureError
                .missingSuspension
        }

        let intentManager = PreparedIntentManager(
            store: AgentHostLocalPreparedIntentStore()
        )
        let grantRequest = try await RequestPathGrantTool(
            manager: intentManager
        ).call(
            .init(
                requestedRootPath: externalRoot.path,
                suggestedRootID: grantedRootID,
                reason: "Exercise Host turn-scoped workspace authority activation."
            ),
            context: .init(
                workspace: workspace
            )
        )
        let intent = try await intentManager.get(
            grantRequest.intentID
        )
        let plan = try PreparedPathGrantOperation.plan(
            from: intent.operation
        )
        let lease = try await host.activate(
            plan,
            context: .init(
                workspace: workspace,
                sessionID: suspended.sessionID,
                preparedIntentID: intent.id
            )
        )

        guard lease.lifetime == .turn,
              lease.sourceTurnID == suspended.sessionID,
              lease.preparedIntentID == intent.id
        else {
            throw AgentHostLocalWorkspaceAccessFixtureError
                .invalidActivatedLease
        }

        let resumed = try await host.resume(
            .init(
                request: approvalRequest,
                resolution: .approval(
                    .approved
                )
            )
        )
        let approvalInvocationCount =
            await approvalProbe.count()

        guard resumed.isCompleted,
              resumed.response?.message.content.text
                == "workspace grant turn ok",
              approvalInvocationCount == 1
        else {
            throw AgentHostLocalWorkspaceAccessFixtureError
                .invalidFirstTurn
        }

        let secondTurn = try await host.submit(
            .init(
                session: sessionID,
                prompt: "Probe the workspace after the previous turn ended."
            )
        )
        let rootSnapshots = await workspaceProbe.snapshot()

        guard secondTurn.isCompleted,
              secondTurn.response?.message.content.text
                == "workspace grant cleanup ok",
              let secondTurnRoots = rootSnapshots.last
        else {
            throw AgentHostLocalWorkspaceAccessFixtureError
                .missingWorkspaceProbe
        }

        guard !secondTurnRoots.contains(
            grantedRootID
        ) else {
            throw AgentHostLocalWorkspaceAccessFixtureError
                .turnGrantLeaked(
                    grantedRootID
                )
        }

        return [
            .field(
                "activated_lifetime",
                lease.lifetime.rawValue
            ),
            .field(
                "activated_turn",
                lease.sourceTurnID ?? "<nil>"
            ),
            .field(
                "approval_tool_invocations",
                String(approvalInvocationCount)
            ),
            .field(
                "second_turn_roots",
                secondTurnRoots.joined(
                    separator: ","
                )
            ),
            .field(
                "turn_grant_removed",
                String(
                    !secondTurnRoots.contains(
                        grantedRootID
                    )
                )
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
