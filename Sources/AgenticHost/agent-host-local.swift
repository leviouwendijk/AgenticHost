import Agentic
import AgenticModels
import AgenticRuntime
import Workspace
import Writers
import Foundation
import IO

/// Host specialization of the shared mutation mode. The Host retains the
/// coordinator; individual workspaces receive restricted participant handles.
public typealias HostMutationPolicy =
    MutationExecutionMode<StandardMutationCoordinator>

public extension AgentHost {
    actor Local:
        Service
    {
        public let runtime: AgenticRuntime
        public let workspace: Workspace?
        public let io: IO
        // A single Host-owned policy. Never expose a coordinator to tools.
        private let mutations: HostMutationPolicy

        private var sessionsByID: [Session.ID: AgentHostLocalSessionState]
        private var sessionOrder: [Session.ID]
        private var runOwners: [String: Session.ID]
        private var programSuspensionsByRunID:
            [String: AgentHostLocalProgramSuspension]
        private var activeProgramsBySession:
            [Session.ID: AgentHostLocalActiveProgram]
        private nonisolated let eventHub: AgentHostLocalEventHub
        private nonisolated let stateHub: AgentHostLocalStateHub

        public init(
            runtime: AgenticRuntime,
            workspace: Workspace? = nil,
            io: IO = .blocking,
            mutations: HostMutationPolicy = .immediate
        ) {
            self.runtime = runtime
            self.workspace = workspace
            self.io = io
            self.mutations = mutations
            self.sessionsByID = [:]
            self.sessionOrder = []
            self.runOwners = [:]
            self.programSuspensionsByRunID = [:]
            self.activeProgramsBySession = [:]
            self.eventHub = .init()
            self.stateHub = .init()
        }

        /// Owner-only observation; never installed as a model-facing tool.
        public func pendingCoordinatedMutationIDs() async -> [UUID] {
            guard case .coordinated(let coordinator) = mutations else { return [] }
            return await coordinator.pending_submission_ids()
        }

        /// Explicit owner publication. Never automatic at run completion;
        /// approval-to-plan binding is a separate required pass.
        public func publishCoordinatedMutations() async throws -> StandardMutationPublication? {
            guard case .coordinated(let coordinator) = mutations else {
                throw Failure.mutationCoordinatorUnavailable
            }
            return try await coordinator.publish()
        }

        public func sessions() async throws -> [Session.Summary] {
            let states = sessionOrder.compactMap { sessionID in
                sessionsByID[sessionID]
            }
            var summaries: [Session.Summary] = []
            summaries.reserveCapacity(states.count)

            for state in states {
                summaries.append(
                    await state.summary()
                )
            }

            return summaries
        }

        public func start(
            _ request: Session.Start
        ) async throws -> Session.Summary {
            let sessionID = request.id ?? .init(
                UUID().uuidString
            )

            guard sessionsByID[sessionID] == nil else {
                throw Failure.duplicateSession(
                    sessionID
                )
            }

            let primaryAgent = agentHostLocalPrimaryAgentID(
                runtime,
                preferred: request.agent
            )
            let defaultExecution = try agentHostLocalDefaultExecution(
                runtime,
                agent: primaryAgent
            )
            eventHub.register(
                sessionID
            )
            stateHub.register(
                sessionID
            )
            let state = AgentHostLocalSessionState(
                id: sessionID,
                agent: primaryAgent,
                title: request.title,
                metadata: request.metadata,
                runtime: runtime,
                defaultExecution: defaultExecution,
                workspace: workspace,
                io: io,
                mutations: mutations,
                eventSink: .init(
                    session: sessionID,
                    hub: eventHub
                ),
                stateSink: .init(
                    session: sessionID,
                    hub: stateHub
                )
            )
            sessionsByID[sessionID] = state
            sessionOrder.append(
                sessionID
            )

            return await state.summary()
        }

        public func submit(
            _ submission: Session.Submission
        ) async throws -> AgentRunner.Result {
            guard let state = sessionsByID[submission.session] else {
                throw Failure.sessionNotFound(
                    submission.session
                )
            }

            let result = try await state.submit(
                submission
            )
            updateRunOwner(
                result,
                session: submission.session
            )

            return result
        }

        public nonisolated func observe(
            _ session: Session.ID
        ) -> AsyncThrowingStream<Run.Event.State, Error> {
            eventHub.stream(
                for: session
            )
        }

        public nonisolated func observeState(
            _ session: Session.ID
        ) -> AsyncThrowingStream<AgentRunStateSnapshot, Error> {
            stateHub.stream(
                for: session
            )
        }

        public func resume(
            _ response: Run.Interaction.Response
        ) async throws -> AgentRunner.Result {
            guard let sessionID = runOwners[response.sessionID] else {
                throw Failure.runNotFound(
                    response.sessionID
                )
            }
            guard let state = sessionsByID[sessionID] else {
                throw Failure.sessionNotFound(
                    sessionID
                )
            }

            let result = try await state.resume(
                response
            )
            updateRunOwner(
                result,
                session: sessionID
            )

            return result
        }

        public func interrupt(
            _ interruption: Session.Interruption
        ) async throws {
            guard let state = sessionsByID[interruption.session] else {
                throw Failure.sessionNotFound(
                    interruption.session
                )
            }

            if let program = activeProgramsBySession[interruption.session],
               interruption.runID == nil || interruption.runID == program.runID
            {
                await program.control.request(
                    interruption.mode,
                    reason: interruption.reason
                )
                return
            }

            if let result = try await state.interrupt(
                runID: interruption.runID,
                mode: interruption.mode,
                reason: interruption.reason
            ) {
                updateRunOwner(
                    result,
                    session: interruption.session
                )
            }
        }

        public func cancel(
            _ session: Session.ID
        ) async throws {
            guard let state = sessionsByID[session] else {
                throw Failure.sessionNotFound(
                    session
                )
            }

            await state.cancel()
            runOwners = runOwners.filter { _, owner in
                owner != session
            }
        }

        public func transcript(
            _ session: Session.ID
        ) async throws -> Transcript {
            guard let state = sessionsByID[session] else {
                throw Failure.sessionNotFound(
                    session
                )
            }

            return await state.transcriptSnapshot()
        }

        public func invokeProgram(
            _ invocation: ProgramInvocation
        ) async throws -> ProgramExecutionRecord {
            let runID = "program-\(UUID().uuidString)"
            let control = Run.Control()
            let session = invocation.metadata["conversation_session_id"].map {
                Session.ID(rawValue: $0)
            }
            if let session {
                guard sessionsByID[session] != nil else {
                    throw Failure.sessionNotFound(session)
                }
                guard activeProgramsBySession[session] == nil else {
                    throw Failure.sessionBusy(session)
                }
                activeProgramsBySession[session] = .init(
                    runID: runID,
                    control: control
                )
            }
            defer {
                if let session {
                    activeProgramsBySession.removeValue(forKey: session)
                }
            }

            let record = try await runtime.executeProgram(
                identifiedBy: invocation.program,
                input: invocation.input,
                realization: invocation.realization,
                sessionID: runID,
                services: try programServices(
                    autonomyMode: invocation.autonomyMode,
                    sessionID: invocation.metadata[
                        "conversation_session_id"
                    ],
                    interruption: control
                ),
                metadata: invocation.metadata
            )

            try retainProgramSuspension(
                record,
                autonomyMode: invocation.autonomyMode
            )

            return record
        }

        public func resumeProgram(
            _ response: Run.Interaction.Response
        ) async throws -> ProgramExecutionRecord {
            guard let suspended = programSuspensionsByRunID[
                response.sessionID
            ] else {
                throw Failure.runNotFound(
                    response.sessionID
                )
            }

            let record = try await runtime.resumeProgram(
                from: suspended.checkpoint,
                interaction: response,
                services: try programServices(
                    autonomyMode: suspended.autonomyMode,
                    sessionID: response.sessionID
                )
            )

            programSuspensionsByRunID.removeValue(
                forKey: response.sessionID
            )
            try retainProgramSuspension(
                record,
                autonomyMode: suspended.autonomyMode
            )

            return record
        }

        public func capabilities() async throws -> Capabilities {
            try agentHostLocalCapabilities(
                runtime
            )
        }

        private func updateRunOwner(
            _ result: AgentRunner.Result,
            session: Session.ID
        ) {
            if result.isSuspended {
                runOwners[result.sessionID] = session
            } else {
                runOwners.removeValue(
                    forKey: result.sessionID
                )
            }
        }

        private func retainProgramSuspension(
            _ record: ProgramExecutionRecord,
            autonomyMode: AutonomyMode
        ) throws {
            guard record.outcome == .suspended else {
                if let sessionID = record.sessionID {
                    programSuspensionsByRunID.removeValue(
                        forKey: sessionID
                    )
                }
                return
            }

            guard let sessionID = record.sessionID,
                  let checkpoint = record.checkpoint
            else {
                throw Failure.invalidProgramSuspension
            }

            programSuspensionsByRunID[sessionID] = .init(
                checkpoint: checkpoint,
                autonomyMode: autonomyMode
            )
        }

        private func programServices(
            autonomyMode: AutonomyMode,
            sessionID: String?,
            interruption: Run.Control? = nil
        ) throws -> RuntimeServices {
            // Programs need their own participant issuance. Until that seam is
            // migrated, refuse to run them with a context that could bypass
            // this Host's coordinated publication boundary.
            if case .coordinated = mutations {
                throw Failure.coordinatedProgramExecutionNotConfigured
            }
            return .init(
                program: .init(
                    tools: GovernedProgramToolExecutor(
                        registry: runtime.tools,
                        policy: .init(
                            autonomyMode: autonomyMode
                        ),
                        context: .init(
                            workspace: try workspace?.context(
                                execution: .init(io: io, mutations: .immediate)
                            )
                        )
                    ),
                    interruption: interruption
                )
            )
        }
    }
}

private struct AgentHostLocalActiveProgram: Sendable {
    let runID: String
    let control: Run.Control
}

private struct AgentHostLocalProgramSuspension:
    Sendable
{
    let checkpoint: ProgramCheckpoint
    let autonomyMode: AutonomyMode
}

public extension AgentHost.Local {
    enum Failure:
        Swift.Error,
        LocalizedError,
        Sendable
    {
        case duplicateSession(AgentHost.Session.ID)
        case sessionNotFound(AgentHost.Session.ID)
        case sessionBusy(AgentHost.Session.ID)
        case runNotFound(String)
        case invalidProgramSuspension
        case mutationCoordinatorUnavailable
        case coordinatedProgramExecutionNotConfigured

        public var errorDescription: String? {
            switch self {
            case .duplicateSession(let session):
                return "AgentHost.Local session '\(session.rawValue)' already exists."

            case .sessionNotFound(let session):
                return "AgentHost.Local session '\(session.rawValue)' was not found."

            case .sessionBusy(let session):
                return "AgentHost.Local session '\(session.rawValue)' already has an active or suspended run."

            case .runNotFound(let runID):
                return "AgentHost.Local runtime run '\(runID)' was not found."

            case .invalidProgramSuspension:
                return "AgentHost.Local received a suspended Program result without resumable checkpoint identity."
            case .mutationCoordinatorUnavailable:
                return "AgentHost.Local does not have an owner mutation coordinator."
            case .coordinatedProgramExecutionNotConfigured:
                return "Coordinated Program invocation requires a separately issued participant; direct program tooling is disabled in coordinated mode."
            }
        }
    }
}

private struct AgentHostLocalRunConfiguration:
    Sendable
{
    let modelSelection: AgentModelSelection
    let configuration: AgentRunner.Configuration
    let capabilityState: AgentCapabilityState
}

private actor AgentHostLocalSessionState {
    private let id: AgentHost.Session.ID
    private let agent: AgentIdentifier?
    private let title: String?
    private let metadata: [String: String]
    private let runtime: AgenticRuntime
    private let defaultExecution: AgentHost.Session.Execution
    private let modelBroker: ModelBroker
    private let workspace: Workspace?
    private let io: IO
    private let mutations: HostMutationPolicy
    // Retain capabilities across suspension/resume and until owner publication
    // or explicit abandonment. Closing a participant withdraws staged work.
    private var mutationParticipantsByRunID: [String: WorkspaceCoordinatedSubmission]
    private let historyStore: AgentHostLocalHistoryStore
    private let eventSink: AgentHostLocalRunEventSink
    private let stateSink: AgentHostLocalRunStateSink

    private var transcript: [Message]
    private var nextOrdinal: Int
    private var runnersByRunID: [String: AgentRunner]
    private var runConfigurationsByRunID:
        [String: AgentHostLocalRunConfiguration]
    private var accessLeases: WorkspaceAccessLeases
    private var activeTask: Task<AgentRunner.Result, Error>?
    private var currentRunID: String?
    private var currentInteraction: Run.Interaction.Request?

    init(
        id: AgentHost.Session.ID,
        agent: AgentIdentifier?,
        title: String?,
        metadata: [String: String],
        runtime: AgenticRuntime,
        defaultExecution: AgentHost.Session.Execution,
        workspace: Workspace?,
        io: IO,
        mutations: HostMutationPolicy,
        eventSink: AgentHostLocalRunEventSink,
        stateSink: AgentHostLocalRunStateSink
    ) {
        self.id = id
        self.agent = agent
        self.title = title
        self.metadata = metadata
        self.runtime = runtime
        self.defaultExecution = defaultExecution
        self.modelBroker = ModelBroker(
            profiles: runtime.profiles,
            gateways: runtime.gateways
        )
        self.workspace = workspace
        self.io = io
        self.mutations = mutations
        self.mutationParticipantsByRunID = [:]
        self.historyStore = .init()
        self.eventSink = eventSink
        self.stateSink = stateSink
        self.transcript = []
        self.nextOrdinal = 1
        self.runnersByRunID = [:]
        self.runConfigurationsByRunID = [:]
        self.accessLeases = .init()
        self.activeTask = nil
        self.currentRunID = nil
        self.currentInteraction = nil
    }

    func summary() -> AgentHost.Session.Summary {
        .init(
            id: id,
            title: title,
            agent: agent,
            interaction: currentInteraction,
            metadata: metadata
        )
    }

    func transcriptSnapshot() -> AgentHost.Transcript {
        .init(
            session: id,
            messages: transcript
        )
    }

    func submit(
        _ submission: AgentHost.Session.Submission
    ) async throws -> AgentRunner.Result {
        guard activeTask == nil,
              currentInteraction == nil
        else {
            throw AgentHost.Local.Failure.sessionBusy(
                id
            )
        }

        // Local transports model-selection intent unchanged. AgenticModels
        // remains the authority that resolves it into a concrete route.
        let execution = submission.execution
        let modelSelection = agentHostLocalModelSelection(
            default: defaultExecution.modelSelection,
            overriding: execution.modelSelection
        )
        let system = execution.instructions?.content
            ?? execution.system
            ?? defaultExecution.instructions?.content
            ?? defaultExecution.system
        let instructionSnapshot = execution.instructions
            ?? execution.system?.instructionSnapshot
            ?? defaultExecution.instructions
            ?? defaultExecution.system?.instructionSnapshot

        let availableCapabilities: AgentCapabilitySet?
        if let defaultAvailable = defaultExecution.availableCapabilities {
            availableCapabilities = (
                execution.availableCapabilities
                ?? defaultAvailable
            ).intersecting(
                defaultAvailable
            )
        } else {
            availableCapabilities = execution.availableCapabilities
        }

        let visibleCapabilities =
            execution.visibleCapabilities
            ?? defaultExecution.visibleCapabilities
            ?? AgentCapabilitySet(
                tools: runtime.installed.tools.modelFacingDefinitions.map(\.identifier)
            )

        let runID = "\(id.rawValue)-turn-\(nextOrdinal)"
        nextOrdinal += 1

        let userMessage = Message(
            role: .user,
            text: submission.prompt
        )
        transcript.append(
            userMessage
        )

        var requestMessages: [Message] = []
        if let system = system?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !system.isEmpty {
            requestMessages.append(
                Message(
                    role: .system,
                    text: system
                )
            )
        }
        requestMessages.append(
            contentsOf: transcript
        )

        var requestMetadata = submission.metadata
        requestMetadata["agent_host_session_id"] = id.rawValue
        requestMetadata["agent_host_run_id"] = runID
        if let instructionSnapshot {
            requestMetadata["instruction_revision"] = instructionSnapshot.revision
            requestMetadata["instruction_references"] = String(
                decoding: try JSONEncoder().encode(instructionSnapshot.references),
                as: UTF8.self
            )
        }

        if let identifier = modelSelection.preferences.preferredProfileIdentifier {
            requestMetadata["preferred_model_profile_id"] = identifier.rawValue
        }

        let request = AgentRequest(
            messages: requestMessages,
            invocationoptions: execution.invocationOptions,
            metadata: requestMetadata
        )
        var configuration = execution.configuration
        configuration.historyPersistenceMode = .checkpointmutation

        // Host runs inherit the complete installed capability universe,
        // not just the subset of Tools projected for model invocation.
        let capabilityState = AgentCapabilityState(
            installed: runtime.installed.capabilities,
            available: availableCapabilities,
            visible: visibleCapabilities
        )
        let runConfiguration = AgentHostLocalRunConfiguration(
            modelSelection: modelSelection,
            configuration: configuration,
            capabilityState: capabilityState
        )
        let runner = try await makeRunner(
            runID: runID,
            runConfiguration: runConfiguration
        )
        runnersByRunID[runID] = runner
        runConfigurationsByRunID[runID] = runConfiguration
        currentRunID = runID

        let task = Task<AgentRunner.Result, Error> {
            try await runner.run(
                request,
                sessionID: runID
            )
        }
        activeTask = task

        return try await finish(
            task,
            runID: runID
        )
    }

    func resume(
        _ response: Run.Interaction.Response
    ) async throws -> AgentRunner.Result {
        guard activeTask == nil else {
            throw AgentHost.Local.Failure.sessionBusy(
                id
            )
        }
        guard currentRunID == response.sessionID,
              let interaction = currentInteraction,
              let runConfiguration =
                runConfigurationsByRunID[response.sessionID]
        else {
            throw AgentHost.Local.Failure.runNotFound(
                response.sessionID
            )
        }

        try activateWorkspaceAccess(
            response,
            interaction: interaction
        )

        let runner = try await makeRunner(
            runID: response.sessionID,
            runConfiguration: runConfiguration
        )
        runnersByRunID[response.sessionID] = runner

        let task = Task<AgentRunner.Result, Error> {
            try await runner.resume(
                interaction: response
            )
        }
        activeTask = task

        return try await finish(
            task,
            runID: response.sessionID
        )
    }

    private func activateWorkspaceAccess(
        _ response: Run.Interaction.Response,
        interaction: Run.Interaction.Request
    ) throws {
        guard interaction.id == response.requestID,
              interaction.sessionID == response.sessionID,
              interaction.kind == response.kind,
              case .workspace_access(let request) = interaction.requirement,
              case .workspace_access(let resolution) = response.resolution,
              let lifetime = resolution.lifetime
        else {
            return
        }

        let lease = try WorkspaceAccessLease(
            request: request,
            lifetime: lifetime,
            durationSeconds: request.durationSeconds,
            sourceTurnID: response.sessionID
        )

        accessLeases = try accessLeases
            .expiring()
            .activating(
                lease,
                baseWorkspace: workspace,
                turnID: response.sessionID
            )
    }

    private func makeRunner(
        runID: String,
        runConfiguration: AgentHostLocalRunConfiguration
    ) async throws -> AgentRunner {
        accessLeases = accessLeases.expiring()

        let effectiveWorkspace = try accessLeases
            .effectiveWorkspace(
                base: workspace,
                turnID: runID
            )

        let execution: WorkspaceExecution
        switch mutations {
        case .immediate:
            execution = .init(io: io, mutations: .immediate)
        case .coordinated(let coordinator):
            if effectiveWorkspace != nil {
                let capability: WorkspaceCoordinatedSubmission
                if let retained = mutationParticipantsByRunID[runID] {
                    capability = retained
                } else {
                    let participant = await coordinator.participant(
                        name: "host:\(id.rawValue):\(runID)"
                    )
                    capability = .init(participant: participant)
                    mutationParticipantsByRunID[runID] = capability
                }
                execution = .init(io: io, mutations: .coordinated(capability))
            } else {
                // No workspace: no file mutation capability is available.
                execution = .init(io: io, mutations: .immediate)
            }
        }

        return AgentRunner(
            model: .init(
                invoker: modelBroker,
                selection: runConfiguration.modelSelection
            ),
            configuration: runConfiguration.configuration,
            tooling: .init(
                registry: runtime.tools,
                workspace: try effectiveWorkspace?.context(execution: execution),
                catalog: runtime.catalog
            ),
            inventory: CapabilityInventory(
                installed: runtime.installed,
                state: runConfiguration.capabilityState
            ),
            recording: .init(
                historyStore: historyStore,
                eventSinks: [
                    eventSink,
                ],
                stateSinks: [
                    stateSink,
                ]
            )
        )
    }

    private func finishTurnAuthority(
        _ runID: String
    ) {
        runConfigurationsByRunID.removeValue(
            forKey: runID
        )
        accessLeases = accessLeases
            .endingTurn(
                runID
            )
            .expiring()
    }

    func interrupt(
        runID requestedRunID: String?,
        mode: Run.Interruption.Mode,
        reason: String?
    ) async throws -> AgentRunner.Result? {
        guard let runID = currentRunID,
              requestedRunID == nil || requestedRunID == runID,
              let runner = runnersByRunID[runID]
        else {
            throw AgentHost.Local.Failure.runNotFound(
                requestedRunID ?? currentRunID ?? "<none>"
            )
        }

        await runner.requestInterruption(
            mode,
            reason: reason
        )

        if let task = activeTask {
            if mode == .urgent,
               let checkpoint = try await historyStore.loadCheckpoint(
                   sessionID: runID
               ),
               checkpoint.phase == .receiving_model_response
            {
                task.cancel()
            }

            return nil
        }

        let result = try await runner.interrupt(
            sessionID: runID,
            mode: mode,
            reason: reason
        )

        return try await consume(
            result,
            runID: runID
        )
    }

    func cancel() async {
        let task = activeTask
        task?.cancel()

        if let task {
            _ = try? await task.value
        }

        activeTask = nil

        if let currentRunID {
            runnersByRunID.removeValue(
                forKey: currentRunID
            )
            finishTurnAuthority(
                currentRunID
            )
            try? await historyStore.deleteCheckpoint(
                sessionID: currentRunID
            )
        }

        currentRunID = nil
        currentInteraction = nil
    }

    private func finish(
        _ task: Task<AgentRunner.Result, Error>,
        runID: String
    ) async throws -> AgentRunner.Result {
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            activeTask = nil

            return try await consume(
                result,
                runID: runID
            )
        } catch {
            activeTask = nil
            runnersByRunID.removeValue(
                forKey: runID
            )
            finishTurnAuthority(
                runID
            )

            if currentRunID == runID {
                currentRunID = nil
                currentInteraction = nil
            }

            try? await historyStore.deleteCheckpoint(
                sessionID: runID
            )
            throw error
        }
    }

    private func consume(
        _ result: AgentRunner.Result,
        runID: String
    ) async throws -> AgentRunner.Result {
        transcript = result.state.messages.filter { message in
            message.role != .system
        }
        currentInteraction = result.interactionRequest

        if result.isCompleted || result.isFailed || result.isInterrupted {
            runnersByRunID.removeValue(
                forKey: runID
            )
            finishTurnAuthority(
                runID
            )

            if !result.isInterrupted {
                try await historyStore.deleteCheckpoint(
                    sessionID: runID
                )
            }

            if currentRunID == runID {
                currentRunID = nil
                currentInteraction = nil
            }
        } else {
            currentRunID = runID
        }

        return result
    }
}

private actor AgentHostLocalHistoryStore: AgentHistoryStore {
    private var checkpoints: [String: AgentRunner.Checkpoint] = [:]

    func loadCheckpoint(
        sessionID: String
    ) async throws -> AgentRunner.Checkpoint? {
        checkpoints[sessionID]
    }

    func saveCheckpoint(
        _ checkpoint: AgentRunner.Checkpoint
    ) async throws {
        checkpoints[checkpoint.id] = checkpoint
    }

    func deleteCheckpoint(
        sessionID: String
    ) async throws {
        checkpoints.removeValue(
            forKey: sessionID
        )
    }
}

private struct AgentHostLocalRunEventSink: Run.EventSink {
    let session: AgentHost.Session.ID
    let hub: AgentHostLocalEventHub

    func record(
        _ event: Run.Event
    ) async throws {
        // The service's observe API publishes run-state events only.
        // Live tool observations remain on the Runtime event channel.
        guard case .state(let state) = event else {
            return
        }

        hub.yield(
            state,
            to: session
        )
    }
}

private final class AgentHostLocalEventHub: @unchecked Sendable {
    private typealias Continuation =
        AsyncThrowingStream<Run.Event.State, Error>.Continuation

    private let lock = NSLock()
    private var knownSessions: Set<AgentHost.Session.ID> = []
    private var observersBySession:
        [AgentHost.Session.ID: [UUID: Continuation]] = [:]

    func register(
        _ session: AgentHost.Session.ID
    ) {
        lock.lock()
        knownSessions.insert(
            session
        )
        lock.unlock()
    }

    func stream(
        for session: AgentHost.Session.ID
    ) -> AsyncThrowingStream<Run.Event.State, Error> {
        let observerID = UUID()

        return AsyncThrowingStream { continuation in
            lock.lock()
            guard knownSessions.contains(session) else {
                lock.unlock()
                continuation.finish(
                    throwing: AgentHost.Local.Failure.sessionNotFound(
                        session
                    )
                )
                return
            }

            var observers = observersBySession[session] ?? [:]
            observers[observerID] = continuation
            observersBySession[session] = observers
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.remove(
                    observerID,
                    from: session
                )
            }
        }
    }

    func yield(
        _ event: Run.Event.State,
        to session: AgentHost.Session.ID
    ) {
        let continuations: [Continuation]

        lock.lock()
        continuations = observersBySession[session].map { observers in
            Array(observers.values)
        } ?? []
        lock.unlock()

        for continuation in continuations {
            continuation.yield(
                event
            )
        }
    }

    private func remove(
        _ observerID: UUID,
        from session: AgentHost.Session.ID
    ) {
        lock.lock()
        observersBySession[session]?.removeValue(
            forKey: observerID
        )
        lock.unlock()
    }
}

private struct AgentHostLocalRunStateSink: AgentRunStateSink {
    let session: AgentHost.Session.ID
    let hub: AgentHostLocalStateHub

    func publish(
        _ state: AgentRunStateSnapshot
    ) async {
        hub.yield(
            state,
            to: session
        )
    }
}

private final class AgentHostLocalStateHub: @unchecked Sendable {
    private typealias Continuation =
        AsyncThrowingStream<AgentRunStateSnapshot, Error>.Continuation

    private let lock = NSLock()
    private var knownSessions: Set<AgentHost.Session.ID> = []
    private var observersBySession:
        [AgentHost.Session.ID: [UUID: Continuation]] = [:]

    func register(
        _ session: AgentHost.Session.ID
    ) {
        lock.lock()
        knownSessions.insert(
            session
        )
        lock.unlock()
    }

    func stream(
        for session: AgentHost.Session.ID
    ) -> AsyncThrowingStream<AgentRunStateSnapshot, Error> {
        let observerID = UUID()

        return AsyncThrowingStream { continuation in
            lock.lock()
            guard knownSessions.contains(session) else {
                lock.unlock()
                continuation.finish(
                    throwing: AgentHost.Local.Failure.sessionNotFound(
                        session
                    )
                )
                return
            }

            var observers = observersBySession[session] ?? [:]
            observers[observerID] = continuation
            observersBySession[session] = observers
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.remove(
                    observerID,
                    from: session
                )
            }
        }
    }

    func yield(
        _ state: AgentRunStateSnapshot,
        to session: AgentHost.Session.ID
    ) {
        let continuations: [Continuation]

        lock.lock()
        continuations = observersBySession[session].map { observers in
            Array(observers.values)
        } ?? []
        lock.unlock()

        for continuation in continuations {
            continuation.yield(
                state
            )
        }
    }

    private func remove(
        _ observerID: UUID,
        from session: AgentHost.Session.ID
    ) {
        lock.lock()
        observersBySession[session]?.removeValue(
            forKey: observerID
        )
        lock.unlock()
    }
}

private func agentHostLocalCapabilities(
    _ runtime: AgenticRuntime
) throws -> AgentHost.Capabilities {
    let inventory = try runtime.toolPresentation()
    let defaultExecution = try agentHostLocalDefaultExecution(
        runtime
    )

    let models: [AgentHost.Capabilities.Model] =
        agentHostLocalProfiles(
            runtime
        ).map { profile in
            .init(
                id: profile.identifier,
                model: profile.model,
                gatewayIdentifier: profile.gatewayIdentifier,
                title: profile.title ?? profile.identifier.rawValue,
                supportsStreaming: profile.capabilities.contains(
                    .streaming
                )
            )
        }

    let instructions = runtime.instructions

    let programs = runtime.programs.definitions

    let modelFacing = Set(inventory.modelFacingEntries.map(\.identifier))
    let installed = runtime.installed.capabilities
    let catalogEntries: [AgentHost.Capabilities.CatalogEntry] =
        runtime.installed.capabilityInspections().compactMap { inspection in
            let kind: AgentHost.Capabilities.CatalogEntry.Kind
            switch inspection.reference {
            case .tool(let identifier):
                guard modelFacing.contains(identifier) else { return nil }
                kind = .tool
            case .program:
                kind = .program
            case .inference:
                kind = .inference
            case .agent:
                kind = .agent
            }
            return .init(
                kind: kind,
                identifier: inspection.identifier,
                namespace: inspection.namespace,
                title: inspection.identifier,
                summary: inspection.purpose
            )
        }
        + runtime.catalog.entries.compactMap { entry in
            guard case .instruction(let instruction) = entry.declaration else {
                return nil
            }
            return .init(
                kind: .instruction,
                identifier: instruction.identifier.rawValue,
                namespace: entry.namespace?.rawValue,
                title: instruction.identifier.rawValue,
                summary: instruction.content
            )
        }

    return .init(
        models: models,
        instructions: instructions,
        programs: programs,
        catalogEntries: catalogEntries.sorted {
            let left = ($0.namespace ?? "", $0.kind.rawValue, $0.identifier)
            let right = ($1.namespace ?? "", $1.kind.rawValue, $1.identifier)
            if left.0 != right.0 { return left.0 < right.0 }
            if left.1 != right.1 { return left.1 < right.1 }
            return left.2 < right.2
        },
        installedCapabilities: .init(
            tools: modelFacing.sorted { $0.rawValue < $1.rawValue },
            programs: installed.programs,
            inferences: installed.inferences,
            agents: installed.agents
        ),
        defaultExecution: defaultExecution
    )
}

private func agentHostLocalPrimaryAgentID(
    _ runtime: AgenticRuntime,
    preferred: AgentIdentifier? = nil
) -> AgentIdentifier? {
    if let preferred {
        return preferred
    }

    for entry in runtime.launches {
        if case .agent(let identifier) = entry.launch {
            return identifier
        }
    }

    return nil
}

private func agentHostLocalDefaultExecution(
    _ runtime: AgenticRuntime,
    agent: AgentIdentifier? = nil
) throws -> AgentHost.Session.Execution {
    guard let identifier = agentHostLocalPrimaryAgentID(
        runtime,
        preferred: agent
    ) else {
        return .init()
    }

    let realization = try runtime.realizeAgent(
        identifiedBy: identifier
    )
    return .init(
        modelSelection: realization.modelSelection,
        system: realization.instructions,
        instructions: realization.instructionSnapshot,
        availableCapabilities: realization.available,
        visibleCapabilities: realization.visible
    )
}

private func agentHostLocalModelSelection(
    default defaultSelection: AgentModelSelection?,
    overriding higherPriority: AgentModelSelection?
) -> AgentModelSelection {
    guard let defaultSelection else {
        return higherPriority
            ?? .executor
    }

    guard let higherPriority else {
        return defaultSelection
    }

    return .init(
        purpose: higherPriority.purpose,
        operation: higherPriority.operation,
        requirements:
            defaultSelection
                .requirements
                .merging(
                    higherPriority.requirements
                ),
        preferences:
            defaultSelection
                .preferences
                .overriding(
                    with: higherPriority.preferences
                ),
        constraints:
            defaultSelection
                .constraints
                .tightened(
                    by: higherPriority.constraints
                ),
        metadata:
            defaultSelection
                .metadata
                .merging(
                    higherPriority.metadata
                ) { _, higher in
                    higher
                }
    )
}

private func agentHostLocalProfiles(
    _ runtime: AgenticRuntime
) -> [AgentModelProfile] {
    runtime.profiles.profilesByIdentifier.values.sorted { lhs, rhs in
        let lhsTitle = lhs.title ?? lhs.identifier.rawValue
        let rhsTitle = rhs.title ?? rhs.identifier.rawValue

        if lhsTitle == rhsTitle {
            return lhs.identifier.rawValue < rhs.identifier.rawValue
        }

        return lhsTitle < rhsTitle
    }
}
