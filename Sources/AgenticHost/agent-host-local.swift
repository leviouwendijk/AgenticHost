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
        private let childRunLimits: AgentRunLimits?
        // Durable record of every step; nil keeps sessions in memory only.
        private let logs: Run.Log.Store?
        private let serviceFactory: @Sendable (Session.ID) throws -> ToolServices
        private var sessionServicesByID: [Session.ID: ToolServices]
        private var programServicesByRunID: [String: ToolServices]

        private var sessionsByID: [Session.ID: AgentHostLocalSessionState]
        private var sessionOrder: [Session.ID]
        private var runOwners: [String: Session.ID]
        private var programSuspensionsByRunID:
            [String: AgentHostLocalProgramSuspension]
        private var activeProgramsBySession:
            [Session.ID: AgentHostLocalActiveProgram]
        private var coordinatedReviews: [UUID: [UUID]]
        private nonisolated let eventHub: AgentHostLocalEventHub
        private nonisolated let stateHub: AgentHostLocalStateHub

        public init(
            runtime: AgenticRuntime,
            workspace: Workspace? = nil,
            io: IO = .blocking,
            mutations: HostMutationPolicy = .immediate,
            childRunLimits: AgentRunLimits? = nil,
            logs: Run.Log.Store? = nil,
            services: @escaping @Sendable (Session.ID) throws -> ToolServices = { _ in .init() }
        ) {
            self.runtime = runtime
            self.workspace = workspace
            self.io = io
            self.mutations = mutations
            self.childRunLimits = childRunLimits
            self.logs = logs
            self.serviceFactory = services
            self.sessionServicesByID = [:]
            self.programServicesByRunID = [:]
            self.sessionsByID = [:]
            self.sessionOrder = []
            self.runOwners = [:]
            self.programSuspensionsByRunID = [:]
            self.activeProgramsBySession = [:]
            self.coordinatedReviews = [:]
            self.eventHub = .init()
            self.stateHub = .init()
        }

        /// Owner-only observation; never installed as a model-facing tool.
        public func delegatedSessions(
            _ session: Session.ID
        ) async throws -> [AgentDelegation.Session] {
            guard let state = sessionsByID[session] else {
                throw Failure.sessionNotFound(session)
            }
            return await state.delegatedSessions()
        }

        public func delegatedWorkers(
            _ session: Session.ID
        ) async throws -> [AgentDelegation.Snapshot] {
            guard let state = sessionsByID[session] else {
                throw Failure.sessionNotFound(session)
            }
            return await state.delegatedWorkers()
        }

        public func interruptWorker(
            _ session: Session.ID,
            workerID: String,
            mode: Run.Interruption.Mode,
            reason: String? = nil
        ) async throws -> AgentExecutor.Result? {
            guard let state = sessionsByID[session] else {
                throw Failure.sessionNotFound(session)
            }
            return try await state.interruptWorker(
                workerID,
                mode: mode,
                reason: reason
            )
        }

        public func resumeWorker(
            _ session: Session.ID,
            workerID: String,
            resolution: Run.Interaction.Resolution
        ) async throws -> AgentExecutor.Result {
            guard let state = sessionsByID[session] else {
                throw Failure.sessionNotFound(session)
            }
            let result = try await state.resumeWorker(
                workerID,
                resolution: resolution
            )
            updateRunOwner(result, session: session)
            return result
        }

        public func continueAfterWorkerInterruption(
            _ session: Session.ID,
            workerID: String
        ) async throws -> AgentExecutor.Result {
            guard let state = sessionsByID[session] else {
                throw Failure.sessionNotFound(session)
            }
            let result = try await state.continueAfterWorkerInterruption(workerID)
            updateRunOwner(result, session: session)
            return result
        }

        public func withdrawWorkerMutations(
            _ session: Session.ID,
            workerID: String
        ) async throws {
            guard let state = sessionsByID[session] else {
                throw Failure.sessionNotFound(session)
            }
            try await state.withdrawWorkerMutations(workerID)
            coordinatedReviews.removeAll()
        }

        public func pendingCoordinatedMutationIDs() async -> [UUID] {
            guard case .coordinated(let coordinator) = mutations else { return [] }
            return await coordinator.pending_submission_ids()
        }

        /// A stable owner-facing mutation review. No filesystem change occurs.
        public func reviewCoordinatedMutations() async throws -> CoordinatedMutationReview? {
            guard case .coordinated(let coordinator) = mutations else {
                throw Failure.mutationCoordinatorUnavailable
            }
            let ids = await coordinator.pending_submission_ids(
                participants: try await idleMutationParticipants()
            )
            guard !ids.isEmpty,
                  let plan = try await coordinator.staged_plan(submissions: ids)
            else { return nil }
            let ticket = UUID()
            coordinatedReviews[ticket] = ids
            return .init(id: ticket, plan: plan, submissionIDs: ids)
        }

        public func publishCoordinatedMutations(
            reviewID: UUID,
            decision: ApprovalDecision
        ) async throws -> StandardMutationPublication? {
            guard case .coordinated(let coordinator) = mutations else {
                throw Failure.mutationCoordinatorUnavailable
            }
            guard let ids = coordinatedReviews.removeValue(forKey: reviewID) else {
                throw Failure.unknownMutationReview(reviewID)
            }
            if decision == .denied || decision == .skipped {
                // A denial closes the review, not another worker's participant.
                return nil
            }
            guard decision == .approved else {
                throw Failure.mutationReviewRequiresDecision
            }
            // A reviewed unit belongs to idle sessions; claims keep it disjoint
            // from work still staged elsewhere, so only its submissions publish.
            let idle = try await idleMutationParticipants()
            guard Set(await coordinator.pending_submission_ids(participants: idle))
                .isSuperset(of: ids) else {
                throw Failure.mutationWorkersActive
            }
            let publication = try await coordinator.publish(submissions: ids)
            coordinatedReviews.removeAll()
            return publication
        }

        /// Legacy no-ticket API cannot bypass explicit review.
        public func publishCoordinatedMutations() async throws -> StandardMutationPublication? {
            guard case .coordinated(let coordinator) = mutations else {
                throw Failure.mutationCoordinatorUnavailable
            }
            if !(await coordinator.pending_submission_ids()).isEmpty {
                throw Failure.mutationReviewRequired
            }
            return nil
        }

        /// Mutation participants of sessions with no active work. Busy
        /// sessions keep their staged units; they never block idle ones.
        private func idleMutationParticipants() async throws -> Set<UUID> {
            var participants: Set<UUID> = []
            for (sessionID, state) in sessionsByID
            where activeProgramsBySession[sessionID] == nil {
                if !(await state.hasActiveMutationWork()) {
                    participants.formUnion(await state.mutationParticipants())
                }
            }
            return participants
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

            let log = try logs?.open(session: sessionID.rawValue)
            // The session's own log backs the Sessions self-review tools.
            let sessionServices = try log.map {
                try serviceFactory(sessionID).inserting($0)
            } ?? serviceFactory(sessionID)
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
                services: sessionServices,
                defaultExecution: defaultExecution,
                workspace: workspace,
                io: io,
                mutations: mutations,
                childRunLimits: childRunLimits,
                log: log,
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
            sessionServicesByID[sessionID] = sessionServices
            sessionOrder.append(
                sessionID
            )

            return await state.summary()
        }

        public func submit(
            _ submission: Session.Submission
        ) async throws -> AgentExecutor.Result {
            guard let state = sessionsByID[submission.session] else {
                throw Failure.sessionNotFound(
                    submission.session
                )
            }

            if case .supersede = submission.existingRunPolicy,
               activeProgramsBySession[submission.session] != nil
            {
                throw Failure.unsupportedProgramReplacement(
                    submission.session
                )
            }

            let result = try await state.submit(
                submission
            )
            if case .supersede = submission.existingRunPolicy {
                runOwners = runOwners.filter { _, owner in
                    owner != submission.session
                }
            }
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
        ) async throws -> AgentExecutor.Result {
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

            if let session {
                programServicesByRunID[runID] = sessionServicesByID[session]
            }
            let record: ProgramExecutionRecord
            do {
                record = try await runtime.executeProgram(
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
            } catch {
                programServicesByRunID.removeValue(forKey: runID)
                throw error
            }
            if record.outcome != .suspended {
                programServicesByRunID.removeValue(forKey: runID)
            }

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
            if record.outcome != .suspended {
                programServicesByRunID.removeValue(forKey: response.sessionID)
            }
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

        public func resolveModel(
            for agent: AgentIdentifier?
        ) async throws -> AgentModelRouteResult {
            let execution = try agentHostLocalDefaultExecution(
                runtime,
                agent: agent
            )
            let selection = try agentHostLocalModelSelection(
                configuration: runtime.application.modelSelection,
                agent: execution.modelSelection,
                session: nil
            )
            let broker = agentHostLocalModelBroker(runtime)
            return try broker.route(selection: selection)
        }

        private func updateRunOwner(
            _ result: AgentExecutor.Result,
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
            let scopedServices = sessionID.flatMap { identifier in
                sessionServicesByID[Session.ID(rawValue: identifier)]
                    ?? programServicesByRunID[identifier]
            } ?? .init()
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
                            ),
                            services: scopedServices
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
        case staleSupersession(
            expected: String?,
            actual: String?
        )
        case unsupportedProgramReplacement(AgentHost.Session.ID)
        case runNotFound(String)
        case invalidProgramSuspension
        case mutationCoordinatorUnavailable
        case unknownMutationReview(UUID)
        case mutationReviewRequired
        case mutationReviewRequiresDecision
        case mutationWorkersActive
        case coordinatedProgramExecutionNotConfigured
        case workerNotAwaitingInteraction(String)

        public var errorDescription: String? {
            switch self {
            case .duplicateSession(let session):
                return "AgentHost.Local session '\(session.rawValue)' already exists."

            case .sessionNotFound(let session):
                return "AgentHost.Local session '\(session.rawValue)' was not found."

            case .sessionBusy(let session):
                return "AgentHost.Local session '\(session.rawValue)' already has an active or suspended run."

            case .staleSupersession(let expected, let actual):
                return "AgentHost.Local supersession expected run '\(expected ?? "<none>" )' but session owns '\(actual ?? "<none>" )'."

            case .unsupportedProgramReplacement(let session):
                return "AgentHost.Local session '\(session.rawValue)' owns a direct Program execution that cannot be superseded by an Agent submission."

            case .runNotFound(let runID):
                return "AgentHost.Local runtime run '\(runID)' was not found."

            case .invalidProgramSuspension:
                return "AgentHost.Local received a suspended Program result without resumable checkpoint identity."
            case .mutationCoordinatorUnavailable:
                return "AgentHost.Local does not have an owner mutation coordinator."
            case .unknownMutationReview(let id):
                return "Coordinated mutation review \(id) has expired; inspect a new preview."
            case .mutationReviewRequired:
                return "Review and approve the exact staged mutation plan before publication."
            case .mutationReviewRequiresDecision:
                return "The coordinated mutation review requires an explicit approve or deny decision."
            case .mutationWorkersActive:
                return "Cannot publish coordinated mutations while any session owns active work."
            case .coordinatedProgramExecutionNotConfigured:
                return "Coordinated Program invocation requires a separately issued participant; direct program tooling is disabled in coordinated mode."
            case .workerNotAwaitingInteraction(let workerID):
                return "Worker '\(workerID)' is not the root's currently suspended child."
            }
        }
    }
}

private struct AgentHostLocalRunConfiguration:
    Sendable
{
    let modelSelection: AgentModelSelection
    let configuration: AgentExecutor.Configuration
    let capabilityState: AgentCapabilityState
    let delegation: AgentDelegation?
}

private actor AgentHostLocalSessionState {
    private let id: AgentHost.Session.ID
    private let agent: AgentIdentifier?
    private let title: String?
    private let metadata: [String: String]
    private let runtime: AgenticRuntime
    private let services: ToolServices
    private let defaultExecution: AgentHost.Session.Execution
    private let modelBroker: ModelBroker
    private let workspace: Workspace?
    private let io: IO
    private let mutations: HostMutationPolicy
    private let childRunLimits: AgentRunLimits?
    // Retain capabilities across suspension/resume and until owner publication
    // or explicit abandonment. Closing a participant withdraws staged work.
    private var mutationParticipantsByRunID: [String: WorkspaceCoordinatedSubmission]
    // Every participant this session created, root and workers: its units.
    private var participantIDs: Set<UUID> = []
    private let historyStore: AgentHostLocalHistoryStore
    private let log: Run.Log?
    private let eventSink: AgentHostLocalRunEventSink
    private let stateSink: AgentHostLocalRunStateSink
    // Canonical messages of every run, readable by read_session_history.
    private let sessionHistory: AgentSessionHistory

    private var transcript: [Message]
    private var nextOrdinal: Int
    private var executorsByRunID: [String: AgentExecutor]
    private var runConfigurationsByRunID:
        [String: AgentHostLocalRunConfiguration]
    // Retained beyond a completed root run until publication or cancellation.
    private var delegationsByRunID: [String: AgentDelegation]
    private var accessLeases: WorkspaceAccessLeases
    private var activeTask: Task<AgentExecutor.Result, Error>?
    private var currentRunID: String?
    private var currentInteraction: Run.Interaction.Request?
    // A reservation prevents actor reentrancy from admitting multiple runs.
    private var admissionInProgress = false
    // This task includes Host result consumption, not just model execution.
    private var finishingRun: (id: String, task: Task<AgentExecutor.Result, Error>)?

    init(
        id: AgentHost.Session.ID,
        agent: AgentIdentifier?,
        title: String?,
        metadata: [String: String],
        runtime: AgenticRuntime,
        services: ToolServices,
        defaultExecution: AgentHost.Session.Execution,
        workspace: Workspace?,
        io: IO,
        mutations: HostMutationPolicy,
        childRunLimits: AgentRunLimits?,
        log: Run.Log?,
        eventSink: AgentHostLocalRunEventSink,
        stateSink: AgentHostLocalRunStateSink
    ) {
        self.id = id
        self.agent = agent
        self.title = title
        self.metadata = metadata
        self.runtime = runtime
        // Reuse a host-supplied history; otherwise install one for this session.
        let sessionHistory = (try? services.require(AgentSessionHistory.self))
            ?? AgentSessionHistory()
        self.sessionHistory = sessionHistory
        self.services = (try? services.inserting(sessionHistory)) ?? services
        self.defaultExecution = defaultExecution
        self.modelBroker = agentHostLocalModelBroker(runtime)
        self.workspace = workspace
        self.io = io
        self.mutations = mutations
        self.childRunLimits = childRunLimits
        self.mutationParticipantsByRunID = [:]
        self.historyStore = .init()
        self.log = log
        self.eventSink = eventSink
        self.stateSink = stateSink
        self.transcript = []
        self.nextOrdinal = 1
        self.executorsByRunID = [:]
        self.runConfigurationsByRunID = [:]
        self.delegationsByRunID = [:]
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

    func mutationParticipants() -> Set<UUID> {
        participantIDs
    }

    func recordMutationParticipant(_ id: UUID) {
        participantIDs.insert(id)
    }

    func hasActiveMutationWork() -> Bool {
        activeTask != nil || admissionInProgress || finishingRun != nil
            || currentRunID != nil
    }

    func delegatedWorkers() async -> [AgentDelegation.Snapshot] {
        var result: [AgentDelegation.Snapshot] = []
        for runID in delegationsByRunID.keys.sorted() {
            if let delegation = delegationsByRunID[runID] {
                result.append(contentsOf: await delegation.snapshots())
            }
        }
        return result
    }

    func delegatedSessions() async -> [AgentDelegation.Session] {
        var result: [AgentDelegation.Session] = []
        for runID in delegationsByRunID.keys.sorted() {
            if let delegation = delegationsByRunID[runID] {
                result.append(contentsOf: await delegation.sessions())
            }
        }
        return result
    }

    private func delegation(for workerID: String) async throws -> AgentDelegation {
        for runID in delegationsByRunID.keys.sorted() {
            guard let delegation = delegationsByRunID[runID],
                  let worker = await delegation.session(workerID),
                  worker.parentSessionID != nil else {
                continue
            }
            return delegation
        }
        throw AgentDelegation.Failure.unknownSession(workerID)
    }

    func interruptWorker(
        _ workerID: String,
        mode: Run.Interruption.Mode,
        reason: String?
    ) async throws -> AgentExecutor.Result? {
        try await delegation(for: workerID).interruptWorker(
            workerID, mode: mode, reason: reason
        )
    }

    func withdrawWorkerMutations(_ workerID: String) async throws {
        try await delegation(for: workerID).withdrawWorkerMutations(of: workerID)
    }

    func resumeWorker(
        _ workerID: String,
        resolution: Run.Interaction.Resolution
    ) async throws -> AgentExecutor.Result {
        guard let interaction = currentInteraction,
              interaction.metadata["delegated_child_session_id"] == workerID else {
            throw AgentHost.Local.Failure.workerNotAwaitingInteraction(workerID)
        }
        return try await resume(
            Run.Interaction.Response(request: interaction, resolution: resolution)
        )
    }

    func continueAfterWorkerInterruption(
        _ workerID: String
    ) async throws -> AgentExecutor.Result {
        guard !admissionInProgress, activeTask == nil, finishingRun == nil,
              let runID = currentRunID,
              let interaction = currentInteraction,
              interaction.metadata["delegated_child_session_id"] == workerID,
              let delegation = runConfigurationsByRunID[runID]?.delegation,
              let child = await delegation.latestResult(workerID),
              child.isInterrupted else {
            throw AgentHost.Local.Failure.workerNotAwaitingInteraction(workerID)
        }
        guard let configuration = runConfigurationsByRunID[runID] else {
            throw AgentHost.Local.Failure.runNotFound(runID)
        }
        admissionInProgress = true
        let executor: AgentExecutor
        do {
            executor = try await makeExecutor(runID: runID, runConfiguration: configuration)
        } catch {
            admissionInProgress = false
            throw error
        }
        executorsByRunID[runID] = executor
        let task = Task<AgentExecutor.Result, Error> {
            try await executor.resume(sessionID: runID)
        }
        activeTask = task
        admissionInProgress = false
        return try await run((task, runID))
    }

    func transcriptSnapshot() -> AgentHost.Transcript {
        .init(
            session: id,
            messages: transcript
        )
    }

    func submit(
        _ submission: AgentHost.Session.Submission
    ) async throws -> AgentExecutor.Result {
        switch submission.existingRunPolicy {
        case .reject:
            guard !admissionInProgress,
                  currentRunID == nil,
                  activeTask == nil,
                  finishingRun == nil,
                  currentInteraction == nil else {
                throw AgentHost.Local.Failure.sessionBusy(id)
            }
            admissionInProgress = true
            let admission: (task: Task<AgentExecutor.Result, Error>, runID: String)
            do {
                admission = try await admitRun(submission)
            } catch {
                admissionInProgress = false
                throw error
            }
            admissionInProgress = false
            return try await run(admission)

        case .supersede(let expectedRunID):
            return try await supersede(submission, expectedRunID: expectedRunID)
        }
    }

    private func admitRun(
        _ submission: AgentHost.Session.Submission
    ) async throws -> (task: Task<AgentExecutor.Result, Error>, runID: String) {

        // Local transports model-selection intent unchanged. AgenticModels
        // remains the authority that resolves it into a concrete route.
        let execution = submission.execution
        let modelSelection = try agentHostLocalModelSelection(
            configuration: runtime.application.modelSelection,
            agent: defaultExecution.modelSelection,
            session: execution.modelSelection
        )
        let system = execution.instructions?.content
            ?? execution.system
            ?? defaultExecution.instructions?.content
            ?? defaultExecution.system
        let instructionSnapshot = execution.instructions
            ?? execution.system?.instructionSnapshot
            ?? defaultExecution.instructions
            ?? defaultExecution.system?.instructionSnapshot

        // Authored capabilities establish initial defaults, not the ceiling
        // for a trusted Host submission. Executable installation remains
        // the maximum authority this session can receive.
        let installedCapabilities = runtime.installed.capabilities
        let availableCapabilities = (
            execution.availableCapabilities
            ?? defaultExecution.availableCapabilities
            ?? installedCapabilities
        ).intersecting(installedCapabilities)

        let visibleCapabilities = (
            execution.visibleCapabilities
            ?? defaultExecution.visibleCapabilities
            ?? AgentCapabilitySet(
                tools: runtime.installed.tools.modelFacingDefinitions.map(\.identifier)
            )
        ).intersecting(availableCapabilities)

        let runID = "\(id.rawValue)-turn-\(nextOrdinal)"
        let userMessage = Message(role: .user, text: submission.prompt)

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
        requestMessages.append(contentsOf: transcript)
        requestMessages.append(userMessage)

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
        let delegation = try agent.map { identifier in
            try AgentDelegation(
                runtime: runtime,
                root: identifier,
                sessionID: runID,
                capabilityState: capabilityState,
                childRunLimits: childRunLimits
            )
        }
        let runConfiguration = AgentHostLocalRunConfiguration(
            modelSelection: modelSelection,
            configuration: configuration,
            capabilityState: capabilityState,
            delegation: delegation
        )
        let executor = try await makeExecutor(
            runID: runID,
            runConfiguration: runConfiguration
        )
        // Commit only after fallible admission setup has succeeded.
        nextOrdinal += 1
        transcript.append(userMessage)
        executorsByRunID[runID] = executor
        runConfigurationsByRunID[runID] = runConfiguration
        if let delegation {
            delegationsByRunID[runID] = delegation
        }
        currentRunID = runID

        let task = Task<AgentExecutor.Result, Error> {
            try await executor.run(
                request,
                sessionID: runID
            )
        }
        activeTask = task

        return (task, runID)
    }

    private func supersede(
        _ submission: AgentHost.Session.Submission,
        expectedRunID: String?
    ) async throws -> AgentExecutor.Result {
        guard !admissionInProgress else {
            throw AgentHost.Local.Failure.sessionBusy(id)
        }
        admissionInProgress = true

        if let expectedRunID, currentRunID != expectedRunID {
            admissionInProgress = false
            throw AgentHost.Local.Failure.staleSupersession(
                expected: expectedRunID,
                actual: currentRunID
            )
        }

        let admission: (task: Task<AgentExecutor.Result, Error>, runID: String)
        do {
            try await settleOccupancy()
            guard currentRunID == nil,
                  activeTask == nil,
                  finishingRun == nil,
                  currentInteraction == nil else {
                throw AgentHost.Local.Failure.sessionBusy(id)
            }
            admission = try await admitRun(submission)
        } catch {
            admissionInProgress = false
            throw error
        }
        admissionInProgress = false
        return try await run(admission)
    }

    private func settleOccupancy() async throws {
        guard let runID = currentRunID else { return }

        if let finishingRun, finishingRun.id == runID {
            if activeTask != nil {
                _ = try await interrupt(
                    runID: runID,
                    mode: .urgent,
                    reason: "Superseded by a new user message."
                )
            }
            // Cancellation of an interrupted model request is expected only
            // after Host cleanup has released the old run.
            do {
                _ = try await finishingRun.task.value
            } catch is CancellationError {
                guard !Task.isCancelled, currentRunID != runID else {
                    throw CancellationError()
                }
            }
        }

        if currentRunID == runID, currentInteraction != nil {
            _ = try await interrupt(
                runID: runID,
                mode: .urgent,
                reason: "Superseded by a new user message."
            )
        }
        guard currentRunID != runID else {
            throw AgentHost.Local.Failure.sessionBusy(id)
        }
    }

    func resume(
        _ response: Run.Interaction.Response
    ) async throws -> AgentExecutor.Result {
        guard !admissionInProgress,
              activeTask == nil,
              finishingRun == nil else {
            throw AgentHost.Local.Failure.sessionBusy(id)
        }
        guard currentRunID == response.sessionID,
              let interaction = currentInteraction,
              let configuration = runConfigurationsByRunID[response.sessionID] else {
            throw AgentHost.Local.Failure.runNotFound(response.sessionID)
        }
        admissionInProgress = true
        let executor: AgentExecutor
        do {
            if interaction.metadata["delegated_child_session_id"] != nil,
               case .workspace_access(let resolution) = response.resolution,
               resolution.lifetime != nil {
                throw AgentHostWorkerScopeError.childWorkspaceExpansionUnsupported
            }
            try activateWorkspaceAccess(response, interaction: interaction)
            executor = try await makeExecutor(
                runID: response.sessionID,
                runConfiguration: configuration
            )
        } catch {
            admissionInProgress = false
            throw error
        }

        executorsByRunID[response.sessionID] = executor
        let task = Task<AgentExecutor.Result, Error> {
            try await executor.resume(interaction: response)
        }
        activeTask = task
        admissionInProgress = false
        return try await run((task, response.sessionID))
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

    private func makeExecutor(
        runID: String,
        runConfiguration: AgentHostLocalRunConfiguration
    ) async throws -> AgentExecutor {
        accessLeases = accessLeases.expiring()

        let effectiveWorkspace = try accessLeases
            .effectiveWorkspace(
                base: workspace,
                turnID: runID
            )

        // A new closure on each resume captures only the authorized Workspace
        // for this turn. Workers never receive publication power: their
        // submissions stay staged until the owner publishes their unit.
        if let delegation = runConfiguration.delegation {
            let mutationMode = mutations
            let workerWorkspace = effectiveWorkspace
            let childIO = io
            await delegation.configureChildTooling { session, request, inherited in
                guard let scope = request.metadata["worker_scope_path"] else {
                    // Pure delegates can still reason and use non-workspace Tools.
                    // An unscoped child never inherits broad write authority.
                    return inherited.using(workspace: nil)
                }
                guard case .coordinated(let coordinator) = mutationMode else {
                    throw AgentHostWorkerScopeError.coordinatedExecutionRequired
                }
                guard workerWorkspace != nil,
                      let parentContext = inherited.workspace else {
                    throw AgentHostWorkerScopeError.workspaceNotConfigured
                }
                let scoped = try agentHostWorkerWorkspace(
                    context: parentContext,
                    requestedScope: scope
                )
                let participant = await coordinator.participant(
                    name: "worker:\(session.id)"
                )
                await self.recordMutationParticipant(participant.id)
                do {
                    let execution = WorkspaceExecution(
                        io: childIO,
                        mutations: .coordinated(
                            WorkspaceCoordinatedSubmission(participant: participant)
                        )
                    )
                    return inherited.using(
                        workspace: try scoped.context(execution: execution)
                    )
                } catch {
                    try? await participant.close()
                    throw error
                }
            }
        }

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
                    // The root's approval reviewed the exact plan, so its own
                    // submissions publish on admission.
                    capability = .init(participant: participant) { submission in
                        try await coordinator.publish(submissions: [submission])
                    }
                    participantIDs.insert(participant.id)
                    mutationParticipantsByRunID[runID] = capability
                }
                execution = .init(io: io, mutations: .coordinated(capability))
            } else {
                // No workspace: no file mutation capability is available.
                execution = .init(io: io, mutations: .immediate)
            }
        }

        return AgentExecutor(
            model: .init(
                invoker: modelBroker,
                selection: runConfiguration.modelSelection
            ),
            configuration: runConfiguration.configuration,
            tooling: .init(
                registry: runtime.tools,
                workspace: try effectiveWorkspace?.context(execution: execution),
                catalog: runtime.catalog,
                services: services
            ),
            inventory: CapabilityInventory(
                installed: runtime.installed,
                state: runConfiguration.capabilityState
            ),
            delegation: runConfiguration.delegation,
            recording: .init(
                historyStore: historyStore,
                eventSinks: [eventSink as any Run.EventSink]
                    + (log.map { [$0.recorder(run: runID)] } ?? []),
                stateSinks: [
                    stateSink,
                    sessionHistory,
                ],
                costTracker: AgentCostTracker(catalog: runtime.pricing)
            )
        )
    }

    private func abandonCoordinatedRun(_ runID: String) async {
        if let delegation = delegationsByRunID.removeValue(forKey: runID) {
            await delegation.withdrawWorkerMutations()
        }
        if let participant = mutationParticipantsByRunID.removeValue(forKey: runID) {
            try? await participant.close()
        }
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
    ) async throws -> AgentExecutor.Result? {
        guard let runID = currentRunID,
              requestedRunID == nil || requestedRunID == runID,
              let executor = executorsByRunID[runID]
        else {
            throw AgentHost.Local.Failure.runNotFound(
                requestedRunID ?? currentRunID ?? "<none>"
            )
        }

        await executor.requestInterruption(mode, reason: reason)
        await runConfigurationsByRunID[runID]?.delegation?.interruptDescendants(
            of: runID,
            mode: mode,
            reason: reason
        )
        // Ownership can change during the await above.
        guard currentRunID == runID else { return nil }

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
        // A finished model task may still be in Host result consumption.
        guard finishingRun?.id != runID, currentInteraction != nil else {
            return nil
        }

        let completion = Task<AgentExecutor.Result, Error> {
            let result = try await executor.interrupt(
                sessionID: runID,
                mode: mode,
                reason: reason
            )
            return try await consume(result, runID: runID)
        }
        finishingRun = (runID, completion)
        do {
            let result = try await completion.value
            if finishingRun?.id == runID { finishingRun = nil }
            return result
        } catch {
            if finishingRun?.id == runID { finishingRun = nil }
            throw error
        }
    }

    func cancel() async {
        let runID = currentRunID
        activeTask?.cancel()
        if let finishingRun, finishingRun.id == runID {
            _ = try? await finishingRun.task.value
        }
        guard currentRunID == runID else { return }

        for retainedRunID in Array(delegationsByRunID.keys) where retainedRunID != runID {
            await abandonCoordinatedRun(retainedRunID)
        }
        if let runID {
            await abandonCoordinatedRun(runID)
            executorsByRunID.removeValue(forKey: runID)
            finishTurnAuthority(runID)
            try? await historyStore.deleteCheckpoint(sessionID: runID)
        }
        currentRunID = nil
        currentInteraction = nil
        activeTask = nil
    }

    private func run(
        _ admission: (task: Task<AgentExecutor.Result, Error>, runID: String)
    ) async throws -> AgentExecutor.Result {
        let completion = Task<AgentExecutor.Result, Error> {
            try await finish(admission.task, runID: admission.runID)
        }
        finishingRun = (admission.runID, completion)
        return try await withTaskCancellationHandler {
            try await completion.value
        } onCancel: {
            completion.cancel()
        }
    }

    private func finish(
        _ task: Task<AgentExecutor.Result, Error>,
        runID: String
    ) async throws -> AgentExecutor.Result {
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            let consumed = try await consume(result, runID: runID)
            activeTask = nil
            if finishingRun?.id == runID { finishingRun = nil }
            return consumed
        } catch {
            await abandonCoordinatedRun(runID)
            executorsByRunID.removeValue(forKey: runID)
            finishTurnAuthority(runID)
            if currentRunID == runID {
                currentRunID = nil
                currentInteraction = nil
            }
            try? await historyStore.deleteCheckpoint(sessionID: runID)
            activeTask = nil
            if finishingRun?.id == runID { finishingRun = nil }
            throw error
        }
    }

    private func consume(
        _ result: AgentExecutor.Result,
        runID: String
    ) async throws -> AgentExecutor.Result {
        transcript = result.state.messages.filter { message in
            message.role != .system
        }
        currentInteraction = result.interactionRequest

        if result.isCompleted || result.isFailed || result.isInterrupted {
            if result.isFailed || result.isInterrupted {
                await abandonCoordinatedRun(runID)
            }
            executorsByRunID.removeValue(
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
    private var checkpoints: [String: AgentExecutor.Checkpoint] = [:]

    func loadCheckpoint(
        sessionID: String
    ) async throws -> AgentExecutor.Checkpoint? {
        checkpoints[sessionID]
    }

    func saveCheckpoint(
        _ checkpoint: AgentExecutor.Checkpoint
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
    configuration: ApplicationModelSelection,
    agent: AgentModelSelection?,
    session: AgentModelSelection?
) throws -> AgentModelSelection {
    let base: AgentModelSelection
    switch (session, agent) {
    case (.some(let explicit), _):
        base = explicit
    case (.none, .some(let defined)):
        base = defined
    case (.none, .none):
        base = .executor
    }
    var contributions: [ModelSelectionResolver.Contribution] = [
        .init(
            source: .application_default,
            selection: .init(
                purpose: base.purpose,
                operation: base.operation,
                requirements: .init(capabilities: []),
                preferences: configuration.preferences
            )
        )
    ]
    if let agent {
        contributions.append(.init(source: .agent, selection: agent))
    }
    if let session {
        // Explicit submission selections are user contributions.
        contributions.append(.init(source: .user, selection: session))
    }
    return try ModelSelectionResolver(
        precedence: configuration.precedence
    ).resolve(contributions).selection
}

private func agentHostLocalModelBroker(
    _ runtime: AgenticRuntime
) -> ModelBroker {
    ModelBroker(
        profiles: runtime.profiles,
        gateways: runtime.gateways,
        selectionResolver: .init(
            precedence: runtime.application.modelSelection.precedence
        )
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
