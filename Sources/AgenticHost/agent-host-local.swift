import Agentic
import AgenticModels
import AgenticRuntime
import Workspace
import Foundation

public extension AgentHost {
    actor Local:
        Service
    {
        public let runtime: AgenticRuntime
        public let workspace: Workspace?

        private var sessionsByID: [Session.ID: AgentHostLocalSessionState]
        private var sessionOrder: [Session.ID]
        private var runOwners: [String: Session.ID]
        private var programSuspensionsByRunID:
            [String: AgentHostLocalProgramSuspension]
        private nonisolated let eventHub: AgentHostLocalEventHub
        private nonisolated let stateHub: AgentHostLocalStateHub

        public init(
            runtime: AgenticRuntime,
            workspace: Workspace? = nil
        ) {
            self.runtime = runtime
            self.workspace = workspace
            self.sessionsByID = [:]
            self.sessionOrder = []
            self.runOwners = [:]
            self.programSuspensionsByRunID = [:]
            self.eventHub = .init()
            self.stateHub = .init()
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

            eventHub.register(
                sessionID
            )
            stateHub.register(
                sessionID
            )

            let defaultExecution = try agentHostLocalDefaultExecution(
                runtime
            )
            let state = AgentHostLocalSessionState(
                id: sessionID,
                title: request.title,
                metadata: request.metadata,
                runtime: runtime,
                defaultExecution: defaultExecution,
                workspace: workspace,
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
        ) async throws -> AgentRunResult {
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
        ) -> AsyncThrowingStream<AgentRunEvent, Error> {
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
            _ response: AgentInteraction.Response
        ) async throws -> AgentRunResult {
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
            let record = try await runtime.executeProgram(
                identifiedBy: invocation.program,
                input: invocation.input,
                realization: invocation.realization,
                services: try programServices(
                    autonomyMode: invocation.autonomyMode,
                    sessionID: invocation.metadata[
                        "conversation_session_id"
                    ]
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
            _ response: AgentInteraction.Response
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
            _ result: AgentRunResult,
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
            sessionID: String?
        ) throws -> AgentRuntimeServices {
            .init(
                program: .init(
                    tools: GovernedProgramToolExecutor(
                        registry: runtime.tools,
                        policy: .init(
                            autonomyMode: autonomyMode
                        ),
                        context: .init(
                            workspace: try workspace?.context()
                        )
                    )
                )
            )
        }
    }
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
            }
        }
    }
}

private struct AgentHostLocalRunConfiguration:
    Sendable
{
    let modelSelection: AgentModelSelection
    let configuration: AgentRunnerConfiguration
    let capabilityState: AgentCapabilityState
}

private actor AgentHostLocalSessionState {
    private let id: AgentHost.Session.ID
    private let title: String?
    private let metadata: [String: String]
    private let runtime: AgenticRuntime
    private let defaultExecution: AgentHost.Session.Execution
    private let modelBroker: ModelBroker
    private let workspace: Workspace?
    private let historyStore: AgentHostLocalHistoryStore
    private let eventSink: AgentHostLocalRunEventSink
    private let stateSink: AgentHostLocalRunStateSink

    private var transcript: [Message]
    private var nextOrdinal: Int
    private var runnersByRunID: [String: AgentRunner]
    private var runConfigurationsByRunID:
        [String: AgentHostLocalRunConfiguration]
    private var accessLeases: WorkspaceAccessLeases
    private var activeTask: Task<AgentRunResult, Error>?
    private var currentRunID: String?
    private var currentInteraction: AgentInteraction.Request?

    init(
        id: AgentHost.Session.ID,
        title: String?,
        metadata: [String: String],
        runtime: AgenticRuntime,
        defaultExecution: AgentHost.Session.Execution,
        workspace: Workspace?,
        eventSink: AgentHostLocalRunEventSink,
        stateSink: AgentHostLocalRunStateSink
    ) {
        self.id = id
        self.title = title
        self.metadata = metadata
        self.runtime = runtime
        self.defaultExecution = defaultExecution
        self.modelBroker = ModelBroker(
            profiles: runtime.profiles,
            gateways: runtime.gateways
        )
        self.workspace = workspace
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
    ) async throws -> AgentRunResult {
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
        let system = execution.system
            ?? defaultExecution.system

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

        let installedCapabilities = AgentCapabilitySet(
            tools: runtime.toolInventory.modelFacingEntries.map(
                \.identifier
            )
        )
        let capabilityState = AgentCapabilityState(
            installed: installedCapabilities,
            available: availableCapabilities,
            visible: visibleCapabilities
        )
        let runConfiguration = AgentHostLocalRunConfiguration(
            modelSelection: modelSelection,
            configuration: configuration,
            capabilityState: capabilityState
        )
        let runner = try makeRunner(
            runID: runID,
            runConfiguration: runConfiguration
        )
        runnersByRunID[runID] = runner
        runConfigurationsByRunID[runID] = runConfiguration
        currentRunID = runID

        let task = Task<AgentRunResult, Error> {
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
        _ response: AgentInteraction.Response
    ) async throws -> AgentRunResult {
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

        let runner = try makeRunner(
            runID: response.sessionID,
            runConfiguration: runConfiguration
        )
        runnersByRunID[response.sessionID] = runner

        let task = Task<AgentRunResult, Error> {
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
        _ response: AgentInteraction.Response,
        interaction: AgentInteraction.Request
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
    ) throws -> AgentRunner {
        accessLeases = accessLeases.expiring()

        let effectiveWorkspace = try accessLeases
            .effectiveWorkspace(
                base: workspace,
                turnID: runID
            )

        return AgentRunner(
            model: .init(
                invoker: modelBroker,
                selection: runConfiguration.modelSelection
            ),
            configuration: runConfiguration.configuration,
            tooling: .init(
                registry: runtime.tools,
                workspace: try effectiveWorkspace?.context(),
                catalog: runtime.catalog
            ),
            capabilityState: runConfiguration.capabilityState,
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
        _ task: Task<AgentRunResult, Error>,
        runID: String
    ) async throws -> AgentRunResult {
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
        _ result: AgentRunResult,
        runID: String
    ) async throws -> AgentRunResult {
        transcript = result.state.messages.filter { message in
            message.role != .system
        }
        currentInteraction = result.interactionRequest

        if result.isCompleted || result.isFailed {
            runnersByRunID.removeValue(
                forKey: runID
            )
            finishTurnAuthority(
                runID
            )
            try await historyStore.deleteCheckpoint(
                sessionID: runID
            )

            if currentRunID == runID {
                currentRunID = nil
            }
        } else {
            currentRunID = runID
        }

        return result
    }
}

private actor AgentHostLocalHistoryStore: AgentHistoryStore {
    private var checkpoints: [String: AgentHistoryCheckpoint] = [:]

    func loadCheckpoint(
        sessionID: String
    ) async throws -> AgentHistoryCheckpoint? {
        checkpoints[sessionID]
    }

    func saveCheckpoint(
        _ checkpoint: AgentHistoryCheckpoint
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

private struct AgentHostLocalRunEventSink: AgentRunEventSink {
    let session: AgentHost.Session.ID
    let hub: AgentHostLocalEventHub

    func recordRunEvent(
        _ event: AgentRunEvent
    ) async throws {
        hub.yield(
            event,
            to: session
        )
    }
}

private final class AgentHostLocalEventHub: @unchecked Sendable {
    private typealias Continuation =
        AsyncThrowingStream<AgentRunEvent, Error>.Continuation

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
    ) -> AsyncThrowingStream<AgentRunEvent, Error> {
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
        _ event: AgentRunEvent,
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
    let inventory = runtime.toolInventory
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

    let skills: [AgentHost.Capabilities.Skill] =
        runtime.skills.skills_sorted.map { skill in
            let required = skill.metadata.tools.required
            let optional = skill.metadata.tools.optional
            let references = required + optional

            return .init(
                id: skill.identifier,
                title: skill.name,
                summary: skill.summary,
                contextText: skill.contextText,
                toolNames: references.map(\.name),
                requiredToolIdentifiers: required.map(\.identifier),
                optionalToolIdentifiers: optional.map(\.identifier)
            )
        }

    let programs = runtime.programs.definitions

    let collections: [AgentHost.Capabilities.ToolCollection] =
        inventory.collections.compactMap { collection in
            let tools: [AgentHost.Capabilities.Tool] =
                collection.toolIdentifiers.compactMap { identifier in
                    guard let entry = inventory.entry(
                        identifiedBy: identifier
                    ), entry.isModelFacing else {
                        return nil
                    }

                    return .init(
                        id: entry.identifier,
                        title: entry.title,
                        summary: entry.description
                    )
                }

            guard !tools.isEmpty else {
                return nil
            }

            return .init(
                id: collection.identifier.rawValue,
                title: collection.title,
                tools: tools
            )
        }

    return .init(
        models: models,
        skills: skills,
        programs: programs,
        tools: .init(
            collections: collections,
            defaultExposedIdentifiers:
                defaultExecution.visibleCapabilities?.tools
                ?? [],
            modelFacingIdentifiers: inventory.modelFacingEntries.map(\.identifier)
        ),
        defaultExecution: defaultExecution
    )
}

private func agentHostLocalDefaultExecution(
    _ runtime: AgenticRuntime
) throws -> AgentHost.Session.Execution {
    for entry in runtime.launches {
        guard case .agent(let identifier) = entry.launch else {
            continue
        }

        let realization = try runtime.realizeAgent(
            identifiedBy: identifier
        )

        return .init(
            modelSelection: realization.modelSelection,
            system: realization.instructions,
            availableCapabilities: realization.available,
            visibleCapabilities: realization.visible
        )
    }

    return .init()
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
        kind: higherPriority.kind,
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
