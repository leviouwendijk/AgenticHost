import Agentic
import AgenticHost
import AgenticCommandLine
import AgenticIO
import AgenticModels
import AgenticRuntime
import Workspace
import Writers
import Foundation
import Primitives
import AgenticInterfaces
import Terminal
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
    var gate: AgentHostLocalResponseGate? = nil

    let descriptor = AgentModelProviderDescriptor(
        source: "agent-host-local-selection",
        displayName: "Agent Host Local Selection"
    )

    var gateways: [AgentModelGatewayFactory] {
        [
            .init(
                identifier: "agent-host-local-selection"
            ) {
                AgentHostLocalSelectionModelGateway(gate: gate)
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
    var gate: AgentHostLocalResponseGate? = nil

    let identifier: AgentModelGatewayIdentifier = "agent-host-local-selection"

    var response: AgentModelResponseProviding {
        AgentHostLocalSelectionResponseProvider(gate: gate)
    }
}

private struct AgentHostLocalSelectionResponseProvider:
    AgentModelResponseProviding
{
    var gate: AgentHostLocalResponseGate? = nil

    func buffered(
        request: AgentRequest,
        route: AgentModelRoute,
        context _: AgentModelInvocationContext
    ) async throws -> AgentResponse {
        if let gate { await gate.park() }

        return AgentResponse(
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
                "visible_tool_count": String(request.tools.count),
                "system_message":
                    request.messages.first(where: {
                        $0.role == .system
                    })?.content.text
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

private actor AgentHostLocalResponseGate {
    private var count = 0
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func park() async {
        count += 1
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                waiting.append(continuation)
            }
        }
    }

    func arrivals() -> Int { count }

    func releaseAll() {
        released = true
        let pending = waiting
        waiting = []
        for continuation in pending {
            continuation.resume()
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

private struct AgentHostLocalApprovalTool: Tool {
    typealias Input = GatewayFlowEchoToolInput
    typealias Output = GatewayFlowEchoToolOutput

    static let definition = ToolDefinition(
        identifier: .init(rawValue: "agent_host_local_approval_tool"),
        purpose: "Bounded mutation fixture for AgentHost.Local typed resume.",
        risk: .boundedmutate
    )

    static var identifier: ToolIdentifier {
        definition.identifier
    }

    let probe: AgentHostLocalApprovalProbe

    func preflight(
        _ input: Input,
        in _: ToolContext
    ) async throws -> ToolPreflight {
        _ = input

        return ToolPreflight(
            tool: Self.definition.identifier,
            risk: Self.definition.risk,
            summary: Self.definition.purpose
        )
    }

    func call(
        _ input: Input,
        in _: ToolContext
    ) async throws -> Output {
        await probe.recordInvocation()

        return .init(
            text: input.text
        )
    }
}

private actor AgentHostLocalWorkspaceAccessProbe {
    private var rootIDsByInvocation: [[String]] = []
    private var participantIDsByInvocation: [UUID?] = []

    func record(
        rootIDs: [String],
        participantID: UUID?
    ) {
        rootIDsByInvocation.append(rootIDs)
        participantIDsByInvocation.append(participantID)
    }

    func snapshot() -> [[String]] {
        rootIDsByInvocation
    }

    func participantSnapshot() -> [UUID?] {
        participantIDsByInvocation
    }
}

private struct AgentHostLocalWorkspaceProbeTool: Tool {
    typealias Input = GatewayFlowEchoToolInput
    typealias Output = GatewayFlowEchoToolOutput

    static let definition = ToolDefinition(
        identifier: .init(rawValue: "agent_host_local_workspace_probe"),
        purpose: "Observe the effective workspace roots for one Host turn.",
        risk: .observe
    )

    static var identifier: ToolIdentifier {
        definition.identifier
    }

    let probe: AgentHostLocalWorkspaceAccessProbe

    func preflight(
        _ input: Input,
        in _: ToolContext
    ) async throws -> ToolPreflight {
        _ = input

        return ToolPreflight(
            tool: Self.definition.identifier,
            risk: Self.definition.risk,
            summary: Self.definition.purpose
        )
    }

    func call(
        _ input: Input,
        in context: ToolContext
    ) async throws -> Output {
        let rootIDs = context.workspace?
            .roots
            .map(\.id.rawValue)
            .sorted()
            ?? []

        let participantID: UUID?
        if let workspace = context.workspace,
           case .coordinated(let capability) = workspace.execution.mutations {
            participantID = capability.id
        } else {
            participantID = nil
        }
        await probe.record(
            rootIDs: rootIDs,
            participantID: participantID
        )

        return .init(
            text: input.text
        )
    }
}

private enum AgentHostLocalWorkspaceAccessFixtureError:
    Error
{
    case missingSuspension
    case invalidFirstTurn
    case missingWorkspaceProbe
    case turnGrantLeaked(String)
    case sessionGrantMissing(String)
}

enum AgentHostLocalFlowTesting {
    static func runCoordinatedSessionOwnership() async throws -> [TestDiagnostic] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try AgenticRuntimeWorkspace.resolve(root.path)
        let probe = AgentHostLocalWorkspaceAccessProbe()
        let callA = ToolCall(
            id: "host-coordinated-probe-A",
            tool: AgentHostLocalWorkspaceProbeTool.identifier,
            input: .object(["arguments": try JSONValue.encoding(GatewayFlowEchoToolInput(text: "A"))])
        )
        let callB = ToolCall(
            id: "host-coordinated-probe-B",
            tool: AgentHostLocalWorkspaceProbeTool.identifier,
            input: .object(["arguments": try JSONValue.encoding(GatewayFlowEchoToolInput(text: "B"))])
        )
        let gateway = GatewayFlowScriptedModelGateway(bufferedResponses: [
            .init(message: .init(role: .assistant, content: .init(blocks: [.tool_call(callA)])), stopReason: .tool_use),
            .init(message: .init(role: .assistant, text: "A done"), stopReason: .end_turn),
            .init(message: .init(role: .assistant, content: .init(blocks: [.tool_call(callB)])), stopReason: .tool_use),
            .init(message: .init(role: .assistant, text: "B done"), stopReason: .end_turn),
        ])
        let application = Agentic.application("host-mutation-coordinator-fixture") {
            tools {
                AgentHostLocalWorkspaceProbeTool(probe: probe)
            }
            modelProvider(AgentHostLocalModelProvider(modelGateway: gateway))
        }
        let runtime = try await AgenticRuntime(application: application)
        let coordinator = StandardMutationCoordinator()
        let host = AgentHost.Local(
            runtime: runtime,
            workspace: workspace,
            io: .blocking,
            mutations: .coordinated(coordinator)
        )
        let sessionA: AgentHost.Session.ID = "coordinated-A"
        let sessionB: AgentHost.Session.ID = "coordinated-B"
        _ = try await host.start(.init(id: sessionA))
        _ = try await host.start(.init(id: sessionB))
        let resultA = try await host.submit(.init(session: sessionA, prompt: "Probe A."))
        let resultB = try await host.submit(.init(session: sessionB, prompt: "Probe B."))
        let observed = (await probe.participantSnapshot()).compactMap { $0 }
        let pending = await host.pendingCoordinatedMutationIDs()
        let emptyPublication = try await host.publishCoordinatedMutations()
        guard resultA.isCompleted, resultB.isCompleted,
              observed.count == 2, observed[0] != observed[1],
              pending.isEmpty, emptyPublication == nil
        else {
            throw AgentHostLocalFlowError.invalidServiceLifecycle
        }
        return [.field("distinct_participants", "\(observed.count)")]
    }

    static func runImmediateMutationPolicy() async throws -> [TestDiagnostic] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-immediate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try AgenticRuntimeWorkspace.resolve(root.path)
        let probe = AgentHostLocalWorkspaceAccessProbe()
        let call = ToolCall(
            id: "host-immediate-probe",
            tool: AgentHostLocalWorkspaceProbeTool.identifier,
            input: .object(["arguments": try JSONValue.encoding(GatewayFlowEchoToolInput(text: "immediate"))])
        )
        let gateway = GatewayFlowScriptedModelGateway(bufferedResponses: [
            .init(message: .init(role: .assistant, content: .init(blocks: [.tool_call(call)])), stopReason: .tool_use),
            .init(message: .init(role: .assistant, text: "done"), stopReason: .end_turn),
        ])
        let application = Agentic.application("host-immediate-mutation-policy-fixture") {
            tools { AgentHostLocalWorkspaceProbeTool(probe: probe) }
            modelProvider(AgentHostLocalModelProvider(modelGateway: gateway))
        }
        let runtime = try await AgenticRuntime(application: application)
        let host = AgentHost.Local(
            runtime: runtime,
            workspace: workspace,
            io: .blocking,
            mutations: .immediate
        )
        let session: AgentHost.Session.ID = "immediate-policy"
        _ = try await host.start(.init(id: session))
        let result = try await host.submit(.init(session: session, prompt: "Probe immediate."))
        let observed = await probe.participantSnapshot()
        guard result.isCompleted, observed.count == 1, observed[0] == nil else {
            throw AgentHostLocalFlowError.invalidServiceLifecycle
        }
        guard await host.pendingCoordinatedMutationIDs().isEmpty else {
            throw AgentHostLocalFlowError.invalidServiceLifecycle
        }
        do {
            _ = try await host.publishCoordinatedMutations()
            throw AgentHostLocalFlowError.invalidServiceLifecycle
        } catch AgentHost.Local.Failure.mutationCoordinatorUnavailable {
            // Immediate mode has no coordinator or publication capability.
        }
        return [.field("immediate_policy", "without_participant")]
    }

    static func runService() async throws -> [TestDiagnostic] {
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
        let firstEvent = Task<Run.Event.State?, Error> {
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
                        runLimits: .init(iterations: 4),
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
              capabilities.installedCapabilities.tools.isEmpty,
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

    static func runPrimaryAgentDefaults() async throws -> [TestDiagnostic] {
        let primaryAgent = HostLocalPrimaryAgent.definition
        let application = Agentic.application(
            "agent-host-local-primary-agent-fixture"
        ) {
            tools {
                GatewayFlowEchoTool()
            }
            install(
                HostLocalPrimaryAgent.self
            )
            AgenticApplicationComponent.launches(
                [
                    .init(
                        identifier: .init(
                            rawValue: "primary_agent"
                        ),
                        title: "Primary Agent",
                        launch: .agent(
                            primaryAgent.identifier
                        )
                    ),
                ]
            )
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
        let capabilities = try await host.capabilities()
        let sessionID: AgentHost.Session.ID =
            "agent-host-local-primary-agent"

        _ = try await host.start(
            .init(
                id: sessionID
            )
        )

        let result = try await host.submit(
            .init(
                session: sessionID,
                prompt: "Use the primary Agent defaults.",
                execution: .init(
                    configuration: .init(
                        runLimits: .init(iterations: 1),
                        autonomyMode: .auto_observe,
                        responseDelivery: .buffered
                    )
                )
            )
        )

        guard capabilities
                .defaultExecution
                .modelSelection?
                .preferences
                .preferredProfileIdentifier?
                .rawValue
                == "agent-host-local-preferred",
              capabilities
                .defaultExecution
                .availableCapabilities?
                .tools
                == [
                    GatewayFlowEchoTool.identifier,
                ],
              capabilities
                .defaultExecution
                .visibleCapabilities?
                .tools
                .isEmpty
                == true,
              result.isCompleted,
              result.response?.metadata["routed_profile_id"]
                == "agent-host-local-preferred",
              result.response?.metadata["routed_model"]
                == "preferred",
              result.response?.metadata["system_message"]
                == "Primary Agent system."
        else {
            throw AgentHostLocalFlowError
                .invalidPrimaryAgentDefaults
        }

        return [
            .field(
                "preferred_profile",
                result.response?.metadata["routed_profile_id"]
                    ?? "<nil>"
            ),
            .field(
                "available_tools",
                String(
                    capabilities
                        .defaultExecution
                        .availableCapabilities?
                        .tools
                        .count
                    ?? 0
                )
            ),
            .field(
                "visible_tools",
                String(
                    capabilities
                        .defaultExecution
                        .visibleCapabilities?
                        .tools
                        .count
                    ?? 0
                )
            ),
        ]
    }

    static func runSelectedAgentSessions() async throws -> [TestDiagnostic] {
        let application = Agentic.application("host-selected-agents-fixture") {
            tools {
                GatewayFlowEchoTool()
            }
            install(HostLocalPrimaryAgent.self)
            install(HostLocalSecondaryAgent.self)
            modelProvider(AgentHostLocalSelectionModelProvider())
        }
        let runtime = try await AgenticRuntime(application: application)
        let host = AgentHost.Local(runtime: runtime)
        let sessionA: AgentHost.Session.ID = "selected-agent-A"
        let sessionB: AgentHost.Session.ID = "selected-agent-B"
        let agentA = HostLocalPrimaryAgent.definition.identifier
        let agentB = HostLocalSecondaryAgent.definition.identifier

        let startedA = try await host.start(.init(id: sessionA, agent: agentA))
        let startedB = try await host.start(.init(id: sessionB, agent: agentB))

        let echo = AgentCapabilitySet(
            tools: [GatewayFlowEchoTool.identifier]
        )
        let executionA = AgentHost.Session.Execution(
            visibleCapabilities: echo,
            configuration: .init(
                runLimits: .init(iterations: 1),
                autonomyMode: .auto_observe,
                responseDelivery: .buffered
            )
        )
        let executionB = AgentHost.Session.Execution(
            availableCapabilities: echo,
            visibleCapabilities: echo,
            configuration: .init(
                runLimits: .init(iterations: 1),
                autonomyMode: .auto_observe,
                responseDelivery: .buffered
            )
        )
        async let pendingA = host.submit(.init(
            session: sessionA,
            prompt: "Only A.",
            execution: executionA
        ))
        async let pendingB = host.submit(.init(
            session: sessionB,
            prompt: "Only B.",
            execution: executionB
        ))
        let (resultA, resultB) = try await (pendingA, pendingB)
        let transcriptA = try await host.transcript(sessionA)
        let transcriptB = try await host.transcript(sessionB)

        var rejectedUninstalled = false
        do {
            _ = try await host.start(.init(
                id: "selected-agent-invalid",
                agent: "agent_host_local_not_installed"
            ))
        } catch {
            rejectedUninstalled = true
        }
        let sessions = try await host.sessions()

        guard startedA.agent == agentA,
              startedB.agent == agentB,
              sessions.count == 2,
              sessions.first(where: { $0.id == sessionA })?.agent == agentA,
              sessions.first(where: { $0.id == sessionB })?.agent == agentB,
              rejectedUninstalled,
              resultA.isCompleted, resultB.isCompleted,
              resultA.response?.metadata["system_message"] == "Primary Agent system.",
              resultB.response?.metadata["system_message"] == "Secondary Agent system.",
              resultA.response?.metadata["routed_profile_id"] == "agent-host-local-preferred",
              resultB.response?.metadata["routed_profile_id"] == "agent-host-local-eligible",
              resultA.response?.metadata["visible_tool_count"] == "1",
              resultB.response?.metadata["visible_tool_count"] == "0",
              transcriptA.messages.first?.content.text == "Only A.",
              transcriptB.messages.first?.content.text == "Only B.",
              !transcriptA.messages.contains(where: { $0.content.text == "Only B." }),
              !transcriptB.messages.contains(where: { $0.content.text == "Only A." })
        else {
            throw AgentHostLocalFlowError.invalidSelectedAgentSessions
        }

        return [
            .field("installed_agents_selected", "2"),
            .field("uninstalled_agent_rejected", String(rejectedUninstalled)),
            .field("primary_visible_tools", resultA.response?.metadata["visible_tool_count"] ?? "unknown"),
            .field("secondary_visible_tools", resultB.response?.metadata["visible_tool_count"] ?? "unknown"),
        ]
    }

    static func runConversationWorkOwnership() async throws -> [TestDiagnostic] {
        let gate = AgentHostLocalResponseGate()
        let application = Agentic.application("host-conversation-work-fixture") {
            tools { GatewayFlowEchoTool() }
            install(HostLocalPrimaryAgent.self)
            install(HostLocalSecondaryAgent.self)
            modelProvider(AgentHostLocalSelectionModelProvider(gate: gate))
        }
        let runtime = try await AgenticRuntime(application: application)
        let service: any AgentHost.Service = AgentHost.Local(runtime: runtime)
        let capabilities = try await service.capabilities()
        let workspace = FileManager.default.temporaryDirectory.path

        let conversationA = try AgenticConversationSession(
            workspace: workspace,
            service: service,
            capabilities: capabilities,
            sessionID: "work-ownership-A",
            primaryAgent: try runtime.realizeAgent(
                identifiedBy: HostLocalPrimaryAgent.definition.identifier
            )
        )
        let conversationB = try AgenticConversationSession(
            workspace: workspace,
            service: service,
            capabilities: capabilities,
            sessionID: "work-ownership-B",
            primaryAgent: try runtime.realizeAgent(
                identifiedBy: HostLocalSecondaryAgent.definition.identifier
            )
        )
        let workA = AgenticConversationWork(conversation: conversationA)
        let workB = AgenticConversationWork(conversation: conversationB)
        let settingsA = await conversationA.presentationSnapshot()
        let settingsB = await conversationB.presentationSnapshot()
        let submissionA = AgenticConversationSubmission(
            body: "Work A.",
            contents: [],
            preferredModelProfileID: settingsA.preferredModelProfileID,
            instructionIDs: [],
            availableCapabilities: settingsA.availableCapabilities,
            visibleCapabilities: settingsA.visibleCapabilities,
            responseDelivery: .buffered
        )
        let submissionB = AgenticConversationSubmission(
            body: "Work B.",
            contents: [],
            preferredModelProfileID: settingsB.preferredModelProfileID,
            instructionIDs: [],
            availableCapabilities: settingsB.availableCapabilities,
            visibleCapabilities: settingsB.visibleCapabilities,
            responseDelivery: .buffered
        )

        _ = try await workA.start(.submission(submissionA))
        _ = try await workB.start(.submission(submissionB))

        var rejectedOverlappingSubmission = false
        do {
            _ = try await workA.start(.submission(submissionA))
        } catch AgenticConversationWork.Failure.busy {
            rejectedOverlappingSubmission = true
        }

        // The model fixtures are parked until both independent submissions
        // reach the provider. Switching which controller is observed cannot
        // cancel either task: their ownership is not tied to terminal focus.
        for _ in 0..<200 {
            if await gate.arrivals() == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let arrivals = await gate.arrivals()
        let activeA = await workA.snapshot()
        let activeB = await workB.snapshot()
        await gate.releaseAll()
        await workA.waitUntilIdle()
        await workB.waitUntilIdle()

        let finalA = await workA.snapshot()
        let finalB = await workB.snapshot()
        let transcriptA = await conversationA.presentationSnapshot()
        let transcriptB = await conversationB.presentationSnapshot()
        let sessions = try await service.sessions()
        guard arrivals == 2,
              activeA.isRunning,
              activeB.isRunning,
              rejectedOverlappingSubmission,
              finalA.generation == 1,
              finalB.generation == 1,
              finalA.completedGeneration == 1,
              finalB.completedGeneration == 1,
              !finalA.isRunning, !finalB.isRunning,
              finalA.lastError == nil, finalB.lastError == nil,
              sessions.count == 2,
              transcriptA.messages.contains(where: { $0.body == "Work A." }),
              transcriptB.messages.contains(where: { $0.body == "Work B." }),
              !transcriptA.messages.contains(where: { $0.body == "Work B." }),
              !transcriptB.messages.contains(where: { $0.body == "Work A." })
        else {
            throw AgentHostLocalFlowError.invalidConversationWorkOwnership
        }

        return [
            .field("parallel_model_arrivals", String(arrivals)),
            .field("same_conversation_overlap_rejected", String(rejectedOverlappingSubmission)),
            .field("work_a_settled", String(finalA.completedGeneration == 1)),
            .field("work_b_settled", String(finalB.completedGeneration == 1)),
        ]
    }

    static func runWorkConsoleSessions() async throws -> [TestDiagnostic] {
        let gate = AgentHostLocalResponseGate()
        let application = Agentic.application("work-console-fixture") {
            tools { GatewayFlowEchoTool() }
            install(HostLocalPrimaryAgent.self)
            install(HostLocalSecondaryAgent.self)
            modelProvider(AgentHostLocalSelectionModelProvider(gate: gate))
        }
        let runtime = try await AgenticRuntime(application: application)
        let service: any AgentHost.Service = AgentHost.Local(runtime: runtime)
        let capabilities = try await service.capabilities()
        let console = await AgenticWorkConsole(
            runtime: runtime,
            service: service,
            capabilities: capabilities,
            workspace: FileManager.default.temporaryDirectory.path
        )
        guard await console.sessionIDs.isEmpty,
              await console.selectedSessionID == nil,
              await console.installedAgents.count == 2,
              try await AgenticWorkConsole.entryAgent(runtime: runtime) == nil,
              try await AgenticWorkConsole.entryAgent(
                  runtime: runtime,
                  explicit: HostLocalSecondaryAgent.definition.identifier
              ) == HostLocalSecondaryAgent.definition.identifier
        else { throw AgentHostLocalFlowError.invalidWorkConsoleSessions }

        let a = try await console.create(
            agent: HostLocalPrimaryAgent.definition.identifier,
            sessionID: "work-console-A"
        )
        let b = try await console.create(
            agent: HostLocalSecondaryAgent.definition.identifier,
            sessionID: "work-console-B"
        )
        let sessionA = try await console.session(for: a)
        let sessionB = try await console.session(for: b)
        let workA = try await console.work(for: a)
        let workB = try await console.work(for: b)
        let settingsA = await sessionA.presentationSnapshot()
        let settingsB = await sessionB.presentationSnapshot()
        let submissionA = AgenticConversationSubmission(
            body: "Console A.",
            contents: [],
            preferredModelProfileID: settingsA.preferredModelProfileID,
            instructionIDs: [],
            availableCapabilities: settingsA.availableCapabilities,
            visibleCapabilities: settingsA.visibleCapabilities,
            responseDelivery: .buffered
        )
        let submissionB = AgenticConversationSubmission(
            body: "Console B.",
            contents: [],
            preferredModelProfileID: settingsB.preferredModelProfileID,
            instructionIDs: [],
            availableCapabilities: settingsB.availableCapabilities,
            visibleCapabilities: settingsB.visibleCapabilities,
            responseDelivery: .buffered
        )
        _ = try await workA.start(.submission(submissionA))
        _ = try await workB.start(.submission(submissionB))
        for _ in 0..<200 {
            if await gate.arrivals() == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let arrivals = await gate.arrivals()
        try await console.select(a)
        let selectedA = await console.selectedSessionID == a
        await console.showDashboard()
        let emptySelection = await console.selectedSessionID == nil
        let prematureExit = await console.requestExit()
        let exitConfirmationPresented = await console.isExitConfirmationPresented
        await console.showDashboard()
        try await console.select(b)
        let selectedB = await console.selectedSessionID == b
        let activeA = await workA.snapshot()
        let activeB = await workB.snapshot()
        try await console.select(a)
        _ = try await console.handle(.key(.control("C")))
        _ = try await console.handle(.key(.space))
        _ = try await console.handle(.key(.char("p")))
        _ = try await console.handle(.key(.char("v")))
        let leaderToDashboard = await console.selectedSessionID == nil
        let bStillRunningAfterLeader = await workB.snapshot().isRunning
        try await console.select(a)
        _ = try await console.handle(.key(.char(":")))
        _ = try await console.handle(.key(.char("E")))
        _ = try await console.handle(.key(.char("x")))
        _ = try await console.handle(.key(.enter))
        let exploreToDashboard = await console.selectedSessionID == nil
        let bStillRunningAfterExplore = await workB.snapshot().isRunning
        await gate.releaseAll()
        await workA.waitUntilIdle()
        await workB.waitUntilIdle()
        let finalA = await workA.snapshot()
        let finalB = await workB.snapshot()
        await console.showDashboard()
        // Neither bare q nor Escape quits the dashboard.
        let escapeExited = try await console.handle(.key(.escape))
        let bareQExited = try await console.handle(.key(.char("q")))
        let commandStartedExit = try await console.handle(.key(.char(":")))
        let commandTypedExit = try await console.handle(.key(.char("q")))
        let commandSubmittedExit = try await console.handle(.key(.enter))
        let idleQuitConfirms = await console.isExitConfirmationPresented
        // Confirmation starts with Cancel; Enter must return, never quit.
        let defaultEnterExited = try await console.handle(.key(.enter))
        let selectionAfterCancel = await console.selectedSessionID
        let modalAfterCancel = await console.isExitConfirmationPresented
        let returnedToDashboard = selectionAfterCancel == nil && !modalAfterCancel
        // Confirmation's destructive option needs explicit selection.
        _ = try await console.handle(.key(.char(":")))
        _ = try await console.handle(.key(.char("q")))
        _ = try await console.handle(.key(.enter))
        _ = try await console.handle(.key(.right))
        let confirmedExit = try await console.handle(.key(.enter))

        // Conversation :q is a Cancel-first archive confirmation, not an
        // application exit. The archive must retain history for later reopening.
        // The composer is already in normal mode after <leader>pv and :Ex.
        // Another Ctrl-C would move compact-composer focus to the transcript.
        await console.showDashboard()
        try await console.select(a)
        _ = try await console.handle(.key(.char(":")))
        _ = try await console.handle(.key(.char("q")))
        let conversationCommandExited = try await console.handle(.key(.enter))
        let conversationDefaultExited = try await console.handle(.key(.enter))
        _ = try await console.handle(.key(.char(":")))
        _ = try await console.handle(.key(.char("q")))
        _ = try await console.handle(.key(.enter))
        _ = try await console.handle(.key(.down))
        let conversationArchiveExitedApplication = try await console.handle(.key(.enter))
        let firstArchiveSucceeded = await console.archivedSessionIDs.contains(a)
        let firstArchiveReturnedToWork = await console.selectedSessionID == nil

        var wideFrame = TerminalFrame(rows: 27, columns: 106)
        AgenticWorkSurface.renderGallery(
            into: &wideFrame,
            in: TerminalRegion(rows: 27, columns: 106),
            section: "Conversations",
            subtitle: "Independent sessions",
            summary: "2 active",
            pads: [
                .init(title: "New conversation", primary: "Choose Agent", secondary: "Independent session", hint: "Enter create", tone: .new),
                .init(title: "Agent A", primary: "Running", secondary: "Model A", hint: "Enter open", tone: .running),
                .init(title: "Agent B", primary: "Idle", secondary: "Model B", hint: "Enter open")
            ],
            selectedIndex: 2,
            footer: "Enter select :q quit",
            commandLine: TerminalCommandLine()
        )
        let wideText = wideFrame.spans.map(\.content).joined(separator: "\n")
        var narrowFrame = TerminalFrame(rows: 27, columns: 48)
        AgenticWorkSurface.renderGallery(
            into: &narrowFrame,
            in: TerminalRegion(rows: 27, columns: 48),
            section: "Agents",
            subtitle: "Available",
            summary: "3 installed",
            pads: [
                .init(title: "Agent 1", primary: "Ready", secondary: "Model", hint: "Enter"),
                .init(title: "Agent 2", primary: "Ready", secondary: "Model", hint: "Enter"),
                .init(title: "Agent 3", primary: "Ready", secondary: "Model", hint: "Enter")
            ],
            selectedIndex: 2,
            footer: "Enter select",
            commandLine: TerminalCommandLine()
        )
        let narrowText = narrowFrame.spans.map(\.content).joined(separator: "\n")
        var confirmationFrame = TerminalFrame(rows: 27, columns: 90)
        AgenticWorkSurface.renderQuit(
            into: &confirmationFrame,
            in: TerminalRegion(rows: 27, columns: 90),
            activeOperations: 1,
            confirms: false
        )
        let confirmationText = confirmationFrame.spans.map(\.content).joined(separator: "\n")
        let transcriptA = await sessionA.presentationSnapshot()
        let transcriptB = await sessionB.presentationSnapshot()
        try await console.select(a)
        // Composer is already in normal mode following the earlier mapping.
        _ = try await console.handle(.key(.char(":")))
        _ = try await console.handle(.key(.char("q")))
        _ = try await console.handle(.key(.enter))
        _ = try await console.handle(.key(.down))
        let archiveExitedApplication = try await console.handle(.key(.enter))
        let archived = await console.archivedSessionIDs.contains(a)
        let storedAfterArchive = try await console.session(for: a)
        let preservedHistory = (await storedAfterArchive.presentationSnapshot()).messages
            .contains(where: { $0.body == "Console A." })
        let otherStillOpen = try await console.lifecycle(for: b) == .active
        try await console.select(a)
        let reopened = try await console.lifecycle(for: a) == .active
        guard arrivals == 2,
              selectedA, selectedB, emptySelection,
              !prematureExit, exitConfirmationPresented,
              !escapeExited, !bareQExited,
              !commandStartedExit, !commandTypedExit, !commandSubmittedExit,
              idleQuitConfirms, !defaultEnterExited, returnedToDashboard,
              confirmedExit,
              !conversationCommandExited, !conversationDefaultExited,
              !conversationArchiveExitedApplication, firstArchiveSucceeded, firstArchiveReturnedToWork,
              wideText.contains("╭"), wideText.contains("╰"),
              wideText.contains("Agent A"), wideText.contains("Agent B"),
              narrowText.contains("Agent 3"),
              confirmationText.contains("Quit application"),
              activeA.isRunning, activeB.isRunning,
              leaderToDashboard, bStillRunningAfterLeader,
              exploreToDashboard, bStillRunningAfterExplore,
              !archiveExitedApplication, archived, preservedHistory,
              otherStillOpen, reopened,
              !finalA.isRunning, !finalB.isRunning,
              finalA.lastError == nil, finalB.lastError == nil,
              transcriptA.messages.contains(where: { $0.body == "Console A." }),
              transcriptB.messages.contains(where: { $0.body == "Console B." }),
              !transcriptA.messages.contains(where: { $0.body == "Console B." }),
              !transcriptB.messages.contains(where: { $0.body == "Console A." })
        else { throw AgentHostLocalFlowError.invalidWorkConsoleSessions }
        return [
            .field("installed_agents", "2"),
            .field("parallel_model_arrivals", String(arrivals)),
            .field("switch_without_cancel", String(selectedA && selectedB)),
            .field("dashboard_without_cancel", String(emptySelection)),
            .field("leader_pv_without_cancel", String(leaderToDashboard && bStillRunningAfterLeader)),
            .field("explore_without_cancel", String(exploreToDashboard && bStillRunningAfterExplore)),
            .field("archive_preserves_history", String(archived && preservedHistory && reopened)),
            .field("quit_while_active_requires_confirmation", String(!prematureExit && exitConfirmationPresented)),
            .field("idle_quit_requires_confirmation", String(idleQuitConfirms)),
            .field("quit_default_cancels", String(!defaultEnterExited && returnedToDashboard)),
            .field("explicit_quit_confirms", String(confirmedExit)),
            .field("conversation_quit_archives", String(!conversationCommandExited && !conversationDefaultExited && !conversationArchiveExitedApplication && firstArchiveSucceeded && firstArchiveReturnedToWork)),
            .field("rounded_responsive_pads", String(wideText.contains("╭") && narrowText.contains("╭"))),
            .field("ambiguous_agent_requires_selection", "true"),
        ]
    }

    static func runSemanticModelSelection() async throws -> [TestDiagnostic] {
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
                        runLimits: .init(iterations: 1),
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

    static func runApprovalResume() async throws -> [TestDiagnostic] {
        let probe = AgentHostLocalApprovalProbe()
        let toolCall = ToolCall(
            id: "agent-host-local-approval-call",
            tool: AgentHostLocalApprovalTool.identifier,
            input: .object([
                "arguments": try JSONValue.encoding(
                    GatewayFlowEchoToolInput(
                        text: "approved payload"
                    )
                ),
            ])
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
        -> [TestDiagnostic]
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

        let workspace = try AgenticRuntimeWorkspace.resolve(
            projectRoot.path
        )
        let grantedRootID = "agent_host_local_temporary"
        let workspaceProbe = AgentHostLocalWorkspaceAccessProbe()
        let turnRequestCall = ToolCall(
            id: "agent-host-local-turn-workspace-request",
            tool: SystemIO.Tools.RequestPathGrant.definition.identifier,
            input: .object([
                "arguments": try JSONValue.encoding(
                    SystemIO.Tools.RequestPathGrant.Input(
                        requestedRootPath: externalRoot.path,
                        suggestedRootID: grantedRootID,
                        reason: "Exercise Host turn-scoped workspace authority resolution."
                    )
                ),
            ])
        )
        let turnProbeCall = ToolCall(
            id: "agent-host-local-turn-workspace-probe",
            tool: AgentHostLocalWorkspaceProbeTool.identifier,
            input: .object([
                "arguments": try JSONValue.encoding(
                    GatewayFlowEchoToolInput(
                        text: "probe granted turn"
                    )
                ),
            ])
        )
        let cleanupProbeCall = ToolCall(
            id: "agent-host-local-cleanup-workspace-probe",
            tool: AgentHostLocalWorkspaceProbeTool.identifier,
            input: .object([
                "arguments": try JSONValue.encoding(
                    GatewayFlowEchoToolInput(
                        text: "probe next turn"
                    )
                ),
            ])
        )
        let sessionRequestCall = ToolCall(
            id: "agent-host-local-session-workspace-request",
            tool: SystemIO.Tools.RequestPathGrant.definition.identifier,
            input: .object([
                "arguments": try JSONValue.encoding(
                    SystemIO.Tools.RequestPathGrant.Input(
                        requestedRootPath: externalRoot.path,
                        suggestedRootID: grantedRootID,
                        reason: "Exercise Host session-scoped workspace authority resolution."
                    )
                ),
            ])
        )
        let sessionProbeCall = ToolCall(
            id: "agent-host-local-session-workspace-probe",
            tool: AgentHostLocalWorkspaceProbeTool.identifier,
            input: .object([
                "arguments": try JSONValue.encoding(
                    GatewayFlowEchoToolInput(
                        text: "probe granted session"
                    )
                ),
            ])
        )
        let persistedSessionProbeCall = ToolCall(
            id: "agent-host-local-persisted-session-workspace-probe",
            tool: AgentHostLocalWorkspaceProbeTool.identifier,
            input: .object([
                "arguments": try JSONValue.encoding(
                    GatewayFlowEchoToolInput(
                        text: "probe persisted session"
                    )
                ),
            ])
        )
        let adapter = GatewayFlowScriptedModelGateway(
            bufferedResponses: [
                AgentResponse(
                    message: .init(
                        role: .assistant,
                        content: .init(
                            blocks: [
                                .tool_call(
                                    turnRequestCall
                                ),
                            ]
                        )
                    ),
                    stopReason: .tool_use
                ),
                AgentResponse(
                    message: .init(
                        role: .assistant,
                        content: .init(
                            blocks: [
                                .tool_call(
                                    turnProbeCall
                                ),
                            ]
                        )
                    ),
                    stopReason: .tool_use
                ),
                AgentResponse(
                    message: .init(
                        role: .assistant,
                        text: "workspace turn grant ok"
                    ),
                    stopReason: .end_turn
                ),
                AgentResponse(
                    message: .init(
                        role: .assistant,
                        content: .init(
                            blocks: [
                                .tool_call(
                                    cleanupProbeCall
                                ),
                            ]
                        )
                    ),
                    stopReason: .tool_use
                ),
                AgentResponse(
                    message: .init(
                        role: .assistant,
                        text: "workspace turn cleanup ok"
                    ),
                    stopReason: .end_turn
                ),
                AgentResponse(
                    message: .init(
                        role: .assistant,
                        content: .init(
                            blocks: [
                                .tool_call(
                                    sessionRequestCall
                                ),
                            ]
                        )
                    ),
                    stopReason: .tool_use
                ),
                AgentResponse(
                    message: .init(
                        role: .assistant,
                        content: .init(
                            blocks: [
                                .tool_call(
                                    sessionProbeCall
                                ),
                            ]
                        )
                    ),
                    stopReason: .tool_use
                ),
                AgentResponse(
                    message: .init(
                        role: .assistant,
                        text: "workspace session grant ok"
                    ),
                    stopReason: .end_turn
                ),
                AgentResponse(
                    message: .init(
                        role: .assistant,
                        content: .init(
                            blocks: [
                                .tool_call(
                                    persistedSessionProbeCall
                                ),
                            ]
                        )
                    ),
                    stopReason: .tool_use
                ),
                AgentResponse(
                    message: .init(
                        role: .assistant,
                        text: "workspace session persistence ok"
                    ),
                    stopReason: .end_turn
                ),
            ]
        )
        let application = Agentic.application(
            "agent-host-local-workspace-access-fixture"
        ) {
            tools {
                SystemIO.Tools.InspectWorkspace()
                SystemIO.Tools.ListPathRoots()
                SystemIO.Tools.ListPathGrants()
                SystemIO.Tools.ExplainPathAccess()
                SystemIO.Tools.SearchFilepaths()
                SystemIO.Tools.RequestPathGrant()
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

        let turnSuspended = try await host.submit(
            .init(
                session: sessionID,
                prompt: "Request temporary turn workspace access."
            )
        )

        guard let turnRequest = turnSuspended.interactionRequest,
              turnRequest.kind == .workspace_access,
              case .workspace_access(let turnWorkspaceRequest) =
                turnRequest.requirement,
              turnWorkspaceRequest.rootID
                == grantedRootID
        else {
            throw AgentHostLocalWorkspaceAccessFixtureError
                .missingSuspension
        }

        let turnResumed = try await host.resume(
            .init(
                request: turnRequest,
                resolution: .workspace_access(
                    .grant_for_turn
                )
            )
        )
        let afterTurnGrantSnapshots = await workspaceProbe.snapshot()

        guard turnResumed.isCompleted,
              turnResumed.response?.message.content.text
                == "workspace turn grant ok",
              let turnGrantedRoots = afterTurnGrantSnapshots.last,
              turnGrantedRoots.contains(
                grantedRootID
              )
        else {
            throw AgentHostLocalWorkspaceAccessFixtureError
                .invalidFirstTurn
        }

        let secondTurn = try await host.submit(
            .init(
                session: sessionID,
                prompt: "Probe workspace after turn-scoped authority ended."
            )
        )
        let afterCleanupSnapshots = await workspaceProbe.snapshot()

        guard secondTurn.isCompleted,
              secondTurn.response?.message.content.text
                == "workspace turn cleanup ok",
              let cleanupRoots = afterCleanupSnapshots.last
        else {
            throw AgentHostLocalWorkspaceAccessFixtureError
                .missingWorkspaceProbe
        }
        guard !cleanupRoots.contains(
            grantedRootID
        ) else {
            throw AgentHostLocalWorkspaceAccessFixtureError
                .turnGrantLeaked(
                    grantedRootID
                )
        }

        let sessionSuspended = try await host.submit(
            .init(
                session: sessionID,
                prompt: "Request temporary session workspace access."
            )
        )

        guard let sessionRequest = sessionSuspended.interactionRequest,
              sessionRequest.kind == .workspace_access
        else {
            throw AgentHostLocalWorkspaceAccessFixtureError
                .missingSuspension
        }

        let sessionResumed = try await host.resume(
            .init(
                request: sessionRequest,
                resolution: .workspace_access(
                    .grant_for_session
                )
            )
        )
        let afterSessionGrantSnapshots = await workspaceProbe.snapshot()

        guard sessionResumed.isCompleted,
              sessionResumed.response?.message.content.text
                == "workspace session grant ok",
              let sessionGrantedRoots = afterSessionGrantSnapshots.last,
              sessionGrantedRoots.contains(
                grantedRootID
              )
        else {
            throw AgentHostLocalWorkspaceAccessFixtureError
                .sessionGrantMissing(
                    grantedRootID
                )
        }

        let fourthTurn = try await host.submit(
            .init(
                session: sessionID,
                prompt: "Probe workspace after session-scoped authority persisted."
            )
        )
        let persistedSnapshots = await workspaceProbe.snapshot()

        guard fourthTurn.isCompleted,
              fourthTurn.response?.message.content.text
                == "workspace session persistence ok",
              let persistedRoots = persistedSnapshots.last,
              persistedRoots.contains(
                grantedRootID
              )
        else {
            throw AgentHostLocalWorkspaceAccessFixtureError
                .sessionGrantMissing(
                    grantedRootID
                )
        }

        return [
            .field(
                "turn_resolution",
                WorkspaceAccessResolution.grant_for_turn.rawValue
            ),
            .field(
                "turn_grant_removed",
                String(
                    !cleanupRoots.contains(
                        grantedRootID
                    )
                )
            ),
            .field(
                "session_resolution",
                WorkspaceAccessResolution.grant_for_session.rawValue
            ),
            .field(
                "session_grant_persisted",
                String(
                    persistedRoots.contains(
                        grantedRootID
                    )
                )
            ),
        ]
    }
}

private enum AgentHostLocalFlowError: Error {
    case invalidServiceLifecycle
    case invalidPrimaryAgentDefaults
    case invalidSelectedAgentSessions
    case invalidConversationWorkOwnership
    case invalidWorkConsoleSessions
    case invalidSemanticModelSelection
    case missingApprovalSuspension
    case missingSessionInteraction
    case invalidApprovalResume
}

private enum HostLocalSecondaryAgent: Agent {
    typealias Input = JSONValue
    typealias Output = JSONValue

    static let purpose = "Prove explicit secondary Agent selection."
    static let instructions: String? = "Secondary Agent system."
    static let capabilities = AgentCapabilities(
        available: .none,
        visible: .none
    )
    static let modelSelection = AgentModelSelection(
        purpose: .executor,
        preferences: .init(
            preferredProfileIdentifier: "agent-host-local-eligible"
        )
    )
    static let definition = AgentDefinition(
        identifier: .init(rawValue: "agent_host_local_secondary"),
        purpose: purpose,
        instructions: instructions,
        capabilities: capabilities,
        modelSelection: modelSelection
    )
}

private enum HostLocalPrimaryAgent: Agent {
    typealias Input = JSONValue
    typealias Output = JSONValue

    static let purpose = "Prove Host inheritance from a launched primary Agent."
    static let instructions: String? = "Primary Agent system."
    static let capabilities = AgentCapabilities(
        available: .init(
            tools: .init(
                members: [GatewayFlowEchoTool.identifier]
            )
        ),
        visible: .none
    )
    static let modelSelection = AgentModelSelection(
        purpose: .executor,
        preferences: .init(
            preferredProfileIdentifier: "agent-host-local-preferred"
        )
    )
    static let definition = AgentDefinition(
        identifier: .init(rawValue: "agent_host_local_primary"),
        purpose: purpose,
        instructions: instructions,
        capabilities: capabilities,
        modelSelection: modelSelection
    )
}
