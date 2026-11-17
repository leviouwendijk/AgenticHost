import Agentic
import AgenticSessions
import AgenticContext
import AgenticIO
import AgenticModels
import AgenticRuntime
import Workspace
import Writers
import Foundation
import IO
import Primitives

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
        private let publication: AgenticSettings.Mutations.Publication
        private let workerPublication: AgenticSettings.Mutations.Workers
        private let serviceFactory: @Sendable (Session.ID) throws -> ToolServices
        // Durable task graph shared by every session; nil leaves task tools unavailable.
        private let tasks: AgentTaskManager?
        private var sessionServicesByID: [Session.ID: ToolServices]
        private var programServicesByRunID: [String: ToolServices]

        private(set) var sessionsByID: [Session.ID: AgentHostLocalSessionState]
        private var sessionOrder: [Session.ID]
        private var runOwners: [String: Session.ID]
        private var programSuspensionsByRunID:
            [String: AgentHostLocalProgramSuspension]
        private var activeProgramsBySession:
            [Session.ID: AgentHostLocalActiveProgram]
        private var coordinatedReviews: [UUID: [UUID]]
        /// Per review ticket: the written, unreviewed publications it covers.
        private var publishedReviews: [UUID: [UUID]] = [:]
        private nonisolated let eventHub: AgentHostLocalEventHub
        private nonisolated let stateHub: AgentHostLocalStateHub

        private let pathSettings: @Sendable () throws -> PathSettings
        public init(
            runtime: AgenticRuntime,
            workspace: Workspace? = nil,
            io: IO = .blocking,
            mutations: HostMutationPolicy = .immediate,
            childRunLimits: AgentRunLimits? = nil,
            logs: Run.Log.Store? = nil,
            publication: AgenticSettings.Mutations.Publication = .approval,
            workers: AgenticSettings.Mutations.Workers = .publish,
            tasks: AgentTaskManager? = nil,
            pathSettings: @escaping @Sendable () throws -> PathSettings = { .init() },
            services: @escaping @Sendable (Session.ID) throws -> ToolServices = { _ in .init() }
        ) {
            self.pathSettings = pathSettings
            self.runtime = runtime
            self.workspace = workspace
            self.io = io
            self.mutations = mutations
            self.childRunLimits = childRunLimits
            self.logs = logs
            self.publication = publication
            self.workerPublication = workers
            self.tasks = tasks
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
            return try await traced(
                "interrupt worker \(workerID) (\(mode.rawValue))",
                in: [state],
                outcome: { $0 == nil ? "requested" : "interrupted" }
            ) {
                try await state.interruptWorker(
                    workerID,
                    mode: mode,
                    reason: reason
                )
            }
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
            let result = try await traced(
                "continue after worker \(workerID) interruption",
                in: [state],
                outcome: { _ in "continued" }
            ) {
                try await state.continueAfterWorkerInterruption(workerID)
            }
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
            try await traced(
                "withdraw worker \(workerID) staged changes",
                in: [state],
                outcome: { "withdrawn" }
            ) {
                try await state.withdrawWorkerMutations(workerID)
            }
            coordinatedReviews.removeAll()
        }

        public func workspace(
            _ session: Session.ID
        ) async throws -> WorkspaceState {
            guard let state = sessionsByID[session] else {
                throw Failure.sessionNotFound(session)
            }
            return try await state.workspaceState()
        }

        public func operatorTrace(
            _ session: Session.ID,
            from index: Int
        ) async throws -> [OperatorTraceEntry] {
            guard let state = sessionsByID[session] else {
                throw Failure.sessionNotFound(session)
            }
            let trace = await state.operatorTrace
            return Array(trace.dropFirst(max(0, index)))
        }

        public func unreviewedChanges(
            _ session: Session.ID
        ) async throws -> Int {
            guard let state = sessionsByID[session] else {
                throw Failure.sessionNotFound(session)
            }
            return await state.unreviewedPublications.count
        }

        public func compact(
            _ session: Session.ID
        ) async throws -> CompactionResult {
            guard let state = sessionsByID[session] else {
                throw Failure.sessionNotFound(session)
            }
            return try await state.compact()
        }

        public func steer(
            _ session: Session.ID,
            text: String
        ) async throws {
            guard let state = sessionsByID[session] else {
                throw Failure.sessionNotFound(session)
            }
            try await state.steer(text)
        }

        public func changeWorkspace(
            _ session: Session.ID,
            _ change: WorkspaceChange,
            command: String
        ) async throws -> WorkspaceChangeResult {
            guard let state = sessionsByID[session] else {
                throw Failure.sessionNotFound(session)
            }
            return try await state.changeWorkspace(change, command: command)
        }

        public func pendingCoordinatedMutationIDs() async -> [UUID] {
            guard case .coordinated(let coordinator) = mutations else { return [] }
            return await coordinator.pending_submission_ids()
        }

        /// A stable owner-facing mutation review. No filesystem change occurs.
        public func reviewCoordinatedMutations(
            session: Session.ID?,
            includingPublished: Bool
        ) async throws -> CoordinatedMutationReview? {
            guard case .coordinated(let coordinator) = mutations else {
                throw Failure.mutationCoordinatorUnavailable
            }
            let ids = await coordinator.pending_submission_ids(
                participants: try await idleMutationParticipants(session: session)
            )
            var published: [StandardMutationPublication] = []
            if includingPublished {
                for (sessionID, state) in sessionsByID where session == nil || session == sessionID {
                    published += await state.unreviewedPublications
                }
            }
            guard !ids.isEmpty || !published.isEmpty else { return nil }
            let plan = ids.isEmpty ? nil : try await coordinator.staged_plan(submissions: ids)
            let ticket = UUID()
            coordinatedReviews[ticket] = ids
            publishedReviews[ticket] = published.map(\.result.id)

            var runs: [UUID: String] = [:]
            for state in sessionsByID.values {
                runs.merge(await state.mutationParticipantRuns()) { first, _ in first }
            }
            let root = (workspace?.roots.first { $0.id == workspace?.defaultRootIdentifier }
                ?? workspace?.roots.first)?.scope.rootURL
            func presented(_ url: URL) -> String {
                guard let root else { return url.path }
                let base = root.standardizedFileURL.path
                let path = url.standardizedFileURL.path
                return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
            }
            func difference(of plan: StandardMutationPlan) -> ToolPreflight.Preview.Difference? {
                root.flatMap { root in
                    try? PreparedMutationDifferenceProjection.project(
                        plan,
                        root: root,
                        presentationPaths: plan.entries.map { $0.entry.targets.map(presented) },
                        title: "Staged changes"
                    )
                }
            }
            let submissions = await coordinator.journal().filter { ids.contains($0.id) }
            var origins: [CoordinatedMutationReview.Origin] = []
            for submission in submissions {
                let own = try await coordinator.staged_plan(submissions: [submission.id])
                origins.append(.init(
                    submissionID: submission.id,
                    runID: runs[submission.participant_id],
                    paths: submission.plan.entries.flatMap { $0.entry.targets.map(presented) },
                    difference: own.flatMap(difference(of:))
                ))
            }
            // Written but unreviewed: judged by the plan each was admitted
            // with, which the journal keeps after publication.
            let journal = await coordinator.journal()
            for publication in published {
                let plans = journal.filter { publication.submission_ids.contains($0.id) }.map(\.plan)
                origins.append(.init(
                    submissionID: publication.result.id,
                    runID: publication.contributions.first.flatMap { runs[$0.participant_id] },
                    paths: plans.flatMap { $0.entries.flatMap { $0.entry.targets.map(presented) } },
                    difference: plans.count == 1 ? difference(of: plans[0]) : nil,
                    isPublished: true
                ))
            }
            return .init(
                id: ticket,
                plan: plan,
                submissionIDs: ids,
                difference: plan.flatMap(difference(of:)),
                origins: origins
            )
        }

        /// Keeps the reviewed publications and rolls back the rejected ones,
        /// newest first. A rollback whose files changed since is refused
        /// before anything is written; later changes go first.
        private func settlePublished(
            keep: [UUID],
            rollBack: [UUID]
        ) async throws {
            guard case .coordinated(let coordinator) = mutations else {
                throw Failure.mutationCoordinatorUnavailable
            }
            var settled: Set<UUID> = Set(keep)
            var order: [(UUID, AgentHostLocalSessionState)] = []
            for state in sessionsByID.values {
                for publication in await state.unreviewedPublications where rollBack.contains(publication.result.id) {
                    order.append((publication.result.id, state))
                }
            }
            func markSettled() async {
                for state in sessionsByID.values {
                    await state.markReviewed(settled)
                }
            }
            do {
                try await rollBackNewestFirst(order, coordinator: coordinator, settled: &settled)
            } catch {
                // What was rolled back before the refusal is reviewed too.
                await markSettled()
                throw error
            }
            await markSettled()
        }

        private func rollBackNewestFirst(
            _ order: [(UUID, AgentHostLocalSessionState)],
            coordinator: StandardMutationCoordinator,
            settled: inout Set<UUID>
        ) async throws {
            // The ledger is oldest first: undo newest first.
            for (id, state) in order.reversed() {
                guard let publication = await state.unreviewed(id),
                      let plan = publication.result.rollback
                else {
                    throw Failure.rollbackUnavailable(id)
                }
                let drifted = plan.driftedTargets()
                guard drifted.isEmpty else {
                    throw Failure.rollbackRefused(drifted.map(\.lastPathComponent))
                }
                let result = try await coordinator.rollback(publication_id: id)
                guard result.status == .applied else {
                    throw Failure.rollbackFailed(result.failed?.message ?? result.status.rawValue)
                }
                settled.insert(id)
                await state.recordRolledBack(publication)
            }
        }

        public func publishCoordinatedMutations(
            reviewID: UUID,
            decision: ApprovalDecision
        ) async throws -> StandardMutationPublication? {
            let ids = coordinatedReviews[reviewID] ?? []
            var action: String
            switch decision {
            case .approved: action = "publish"
            case .denied: action = "discard"
            default: action = "keep"
            }
            action += " staged review (\(ids.count) \(ids.count == 1 ? "unit" : "units"))"
            return try await traced(
                action,
                in: await owners(of: ids).map(\.state),
                outcome: { publication in
                    switch decision {
                    case .approved: return publication?.operatorOutcome ?? "nothing to publish"
                    case .denied: return "discarded"
                    default: return "kept staged"
                    }
                }
            ) {
                try await publishReviewed(reviewID: reviewID, decision: decision)
            }
        }

        private func publishReviewed(
            reviewID: UUID,
            decision: ApprovalDecision
        ) async throws -> StandardMutationPublication? {
            guard case .coordinated(let coordinator) = mutations else {
                throw Failure.mutationCoordinatorUnavailable
            }
            guard let ids = coordinatedReviews.removeValue(forKey: reviewID) else {
                throw Failure.unknownMutationReview(reviewID)
            }
            let published = publishedReviews.removeValue(forKey: reviewID) ?? []
            if decision == .skipped {
                // Skipping closes the review; the units stay staged.
                return nil
            }
            if decision == .denied {
                // Denial discards the reviewed units and releases their claims,
                // and rolls back what was already written.
                for state in sessionsByID.values {
                    await state.discardStagedMutations(ids)
                }
                coordinatedReviews.removeAll()
                try await settlePublished(keep: [], rollBack: published)
                return nil
            }
            try await settlePublished(keep: published, rollBack: [])
            guard !ids.isEmpty else { return nil }
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
            if let publication {
                for state in sessionsByID.values {
                    await state.recordPublication(publication)
                }
            }
            return publication
        }

        public func decideCoordinatedMutations(
            reviewID: UUID,
            decisions: [UUID: ApprovalDecision]
        ) async throws -> StandardMutationPublication? {
            let ids = coordinatedReviews[reviewID] ?? []
            let approved = decisions.values.filter { $0 == .approved }.count
            let denied = decisions.values.filter { $0 == .denied }.count
            let action = "decide staged review: publish \(approved), discard \(denied), keep \(ids.count - approved - denied)"
            return try await traced(
                action,
                in: await owners(of: ids).map(\.state),
                outcome: { $0?.operatorOutcome ?? "nothing published" }
            ) {
                try await decideReviewed(reviewID: reviewID, decisions: decisions)
            }
        }

        private func decideReviewed(
            reviewID: UUID,
            decisions: [UUID: ApprovalDecision]
        ) async throws -> StandardMutationPublication? {
            guard case .coordinated(let coordinator) = mutations else {
                throw Failure.mutationCoordinatorUnavailable
            }
            guard let ids = coordinatedReviews[reviewID] else {
                throw Failure.unknownMutationReview(reviewID)
            }
            let published = publishedReviews[reviewID] ?? []
            guard Set(decisions.keys).isSubset(of: Set(ids).union(published)) else {
                throw Failure.mutationReviewRequiresDecision
            }
            try await settlePublished(
                keep: published.filter { decisions[$0] == .approved },
                rollBack: published.filter { decisions[$0] == .denied }
            )
            let approved = ids.filter { decisions[$0] == .approved }
            let denied = ids.filter { decisions[$0] == .denied }
            if !approved.isEmpty {
                let idle = try await idleMutationParticipants()
                guard Set(await coordinator.pending_submission_ids(participants: idle))
                    .isSuperset(of: approved) else {
                    throw Failure.mutationWorkersActive
                }
            }
            coordinatedReviews.removeAll()
            for state in sessionsByID.values where !denied.isEmpty {
                try await state.discardReviewedMutations(denied)
            }
            guard !approved.isEmpty,
                  let publication = try await coordinator.publish(submissions: approved)
            else {
                return nil
            }
            for state in sessionsByID.values {
                await state.recordPublication(publication)
            }
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

        /// What a session's log header records, so sessions can be told
        /// apart later: workspace, agent, title and the start metadata.
        private func logMetadata(
            _ request: Session.Start
        ) -> [String: String] {
            var metadata = request.metadata
            let root = workspace?.roots.first { $0.id == workspace?.defaultRootIdentifier }
                ?? workspace?.roots.first
            metadata["workspace"] = root?.scope.rootURL.path
            metadata["agent"] = agentHostLocalPrimaryAgentID(runtime, preferred: request.agent)?.rawValue
            metadata["title"] = request.title
            return metadata
        }

        /// Mutation participants of sessions with no active work. Busy
        /// sessions keep their staged units; they never block idle ones.
        private func idleMutationParticipants(
            session: Session.ID? = nil
        ) async throws -> Set<UUID> {
            var participants: Set<UUID> = []
            for (sessionID, state) in sessionsByID
            where activeProgramsBySession[sessionID] == nil
                && (session == nil || session == sessionID) {
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

            let log = try logs?.open(
                session: sessionID.rawValue,
                metadata: logMetadata(request)
            )
            // The session's own log backs the Sessions self-review tools.
            let sessionServices = try agentHostLocalSessionCatalog(logs, in: agentHostLocalTaskServices(
                log.map {
                    // As itself for the runtime (read_result), and as a
                    // Sessions log for the self-review tools.
                    try serviceFactory(sessionID)
                        .inserting($0)
                        .inserting($0 as any Sessions.LogReading)
                } ?? serviceFactory(sessionID),
                tasks: tasks,
                sessionID: sessionID
            ))
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
                publication: publication,
                workers: workerPublication,
                pathSettings: pathSettings,
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
            await state.applySettingsPaths()
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

            let result = try await traced(
                "interrupt (\(interruption.mode.rawValue))",
                in: [state],
                outcome: { $0 == nil ? "requested" : "interrupted" }
            ) {
                try await state.interrupt(
                    runID: interruption.runID,
                    mode: interruption.mode,
                    reason: interruption.reason
                )
            }
            if let result {
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

            await state.record(.operator_command, "cancel → cancelled")
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
            // The session's single admission rule decides, as for a
            // submission: a Program never runs beside an Agent run.
            var occupied: AgentHostLocalSessionState?
            if let session {
                guard let state = sessionsByID[session] else {
                    throw Failure.sessionNotFound(session)
                }
                guard activeProgramsBySession[session] == nil else {
                    throw Failure.sessionBusy(session)
                }
                try await state.beginProgram(runID)
                occupied = state
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
            func release() async {
                await occupied?.endProgram()
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
                services: try await programServices(
                    autonomyMode: invocation.autonomyMode,
                    sessionID: invocation.metadata[
                        "conversation_session_id"
                    ],
                    interruption: control,
                    owner: occupied.map { ($0, runID) }
                ),
                metadata: invocation.metadata
                )
            } catch {
                programServicesByRunID.removeValue(forKey: runID)
                await release()
                throw error
            }
            await release()
            if record.outcome != .suspended {
                programServicesByRunID.removeValue(forKey: runID)
                await occupied?.settleProgram(runID: runID)
            }

            try retainProgramSuspension(
                record,
                autonomyMode: invocation.autonomyMode,
                session: session
            )

            return record
        }

        public func invokeInference(
            _ request: InferenceInvocationRequest
        ) async throws -> InferenceInvocationResult {
            let state = try request.session.map { session in
                guard let state = sessionsByID[session] else {
                    throw Failure.sessionNotFound(session)
                }
                return state
            }
            let selection = try agentHostLocalModelSelection(
                configuration: runtime.application.modelSelection,
                agent: nil,
                session: nil
            )
            let action = "inference \(request.inference.rawValue)"
            do {
                let response = try await runtime.executeInference(
                    identifiedBy: request.inference,
                    input: request.input,
                    using: runtime.makeInferenceExecutor(
                        modelInvoker: agentHostLocalModelBroker(runtime)
                    ),
                    context: .init(modelSelection: selection)
                )
                let output = try JSONDecoder().decode(JSONValue.self, from: response.output)
                await state?.record(.operator_command, "\(action) → completed")
                return .init(output: output, record: response.record)
            } catch {
                await state?.record(.operator_command, "\(action) → failed: \(error.localizedDescription)")
                throw error
            }
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

            let owner = suspended.session.flatMap { sessionsByID[$0] }
            let record = try await runtime.resumeProgram(
                from: suspended.checkpoint,
                interaction: response,
                services: try await programServices(
                    autonomyMode: suspended.autonomyMode,
                    sessionID: response.sessionID,
                    owner: owner.map { ($0, response.sessionID) }
                )
            )

            programSuspensionsByRunID.removeValue(
                forKey: response.sessionID
            )
            if record.outcome != .suspended {
                programServicesByRunID.removeValue(forKey: response.sessionID)
                await owner?.settleProgram(runID: response.sessionID)
            }
            try retainProgramSuspension(
                record,
                autonomyMode: suspended.autonomyMode,
                session: suspended.session
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
            autonomyMode: AutonomyMode,
            session: Session.ID?
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
                autonomyMode: autonomyMode,
                session: session
            )
        }

        /// `owner` is the conversation session the Program runs in; its
        /// workspace carries that session's leases and, when mutations are
        /// coordinated, the Program's own participant. A Program without an
        /// owning session has no review to stage into, so coordinated
        /// mutations refuse it.
        private func programServices(
            autonomyMode: AutonomyMode,
            sessionID: String?,
            interruption: Run.Control? = nil,
            owner: (state: AgentHostLocalSessionState, runID: String)? = nil
        ) async throws -> RuntimeServices {
            let programWorkspace: WorkspaceContext?
            if let owner {
                programWorkspace = try await owner.state.programWorkspace(runID: owner.runID)
            } else if case .coordinated = mutations {
                throw Failure.coordinatedProgramExecutionNotConfigured
            } else {
                programWorkspace = try workspace?.context(
                    execution: .init(io: io, mutations: .immediate)
                )
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
                            workspace: programWorkspace,
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
    /// The conversation session that owns the Program's participant.
    let session: AgentHost.Session.ID?
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
        case workspaceNotConfigured
        case notSteerable(AgentHost.Session.ID)
        case compactionWhileExecuting
        case rollbackUnavailable(UUID)
        case rollbackRefused([String])
        case rollbackFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notSteerable(let session):
                return "Session '\(session.rawValue)' has no executing run to steer."

            case .rollbackUnavailable:
                return "That change can no longer be rolled back here; use git to undo it."

            case .rollbackRefused(let files):
                return "Not rolled back: \(files.joined(separator: ", ")) changed since. Roll back the later changes to them first, or keep this one."

            case .rollbackFailed(let message):
                return "Rollback failed: \(message). Check the files before writing again."

            case .compactionWhileExecuting:
                return "A run is executing; compact when it pauses or settles, so no request changes mid-turn."

            case .workspaceNotConfigured:
                return "This session has no workspace."

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

actor AgentHostLocalSessionState {
    let id: AgentHost.Session.ID
    private let agent: AgentIdentifier?
    private let title: String?
    private let metadata: [String: String]
    private let runtime: AgenticRuntime
    private let services: ToolServices
    private let defaultExecution: AgentHost.Session.Execution
    private let modelBroker: ModelBroker
    let workspace: Workspace?
    private let io: IO
    private let mutations: HostMutationPolicy
    private let childRunLimits: AgentRunLimits?
    // Retain capabilities across suspension/resume and until owner publication
    // or explicit abandonment. Closing a participant withdraws staged work.
    private var mutationParticipantsByRunID: [String: WorkspaceCoordinatedSubmission]
    // Every participant this session created, root and workers: its units.
    private var participantIDs: Set<UUID> = []
    // The run each participant was created for: where its changes came from.
    private var participantRuns: [UUID: String] = [:]
    private let historyStore: AgentHostLocalHistoryStore
    let log: Run.Log?
    private let publication: AgenticSettings.Mutations.Publication
    private let workerPublication: AgenticSettings.Mutations.Workers
    /// Changes written to disk and not yet reviewed, oldest first. Review
    /// keeps or rolls them back; nothing leaves this list on its own.
    var unreviewedPublications: [StandardMutationPublication] = []
    // Submissions whose staging was already recorded in the log.
    private var recordedStaged: Set<UUID> = []
    private let eventSink: AgentHostLocalRunEventSink
    private let stateSink: AgentHostLocalRunStateSink
    // Canonical messages of every run, readable by read_session_history.
    private let sessionHistory: Sessions.HistoryStore

    private var transcript: [Message]
    var transcriptMessages: [Message] { transcript }
    var isExecuting: Bool { activeTask != nil }
    private var nextOrdinal: Int
    private var executorsByRunID: [String: AgentExecutor]
    private var runConfigurationsByRunID:
        [String: AgentHostLocalRunConfiguration]
    // Retained beyond a completed root run until publication or cancellation.
    private var delegationsByRunID: [String: AgentDelegation]
    var accessLeases: WorkspaceAccessLeases
    // Workspace changes the model has not been told about yet.
    var pendingWorkspaceNotes: [String] = []
    /// This conversation's compactions, applied to every run's requests.
    let compactionLedger = Context.CompactionLedger()
    /// Operator commands and their effects, as recorded in the session log.
    var operatorTrace: [AgentHost.OperatorTraceEntry] = []
    // What the previous turn ran with; a turn traces what it changes.
    var turnSettings: AgentHost.TurnSettings?
    // Every change to occupancy wakes submissions queued behind it.
    private var activeTask: Task<AgentExecutor.Result, Error>? { didSet { occupancyChanged() } }
    private(set) var currentRunID: String? { didSet { occupancyChanged() } }
    private var currentInteraction: Run.Interaction.Request? { didSet { occupancyChanged() } }
    // A reservation prevents actor reentrancy from admitting multiple runs.
    private var admissionInProgress = false { didSet { occupancyChanged() } }
    // This task includes Host result consumption, not just model execution.
    private var finishingRun: (id: String, task: Task<AgentExecutor.Result, Error>)? { didSet { occupancyChanged() } }
    let pathSettings: @Sendable () throws -> AgentHost.PathSettings
    // Steering a run ended before taking, for the next turn's message.
    var undeliveredSteering: [String] = []
    // A direct Program executing in this session; it occupies the session
    // like a run does.
    private var programRunID: String? { didSet { occupancyChanged() } }
    // Queued submissions in arrival order, and who is waiting for a change.
    private var queuedAdmissions: [UUID] = []
    private var occupancyWaiters: [CheckedContinuation<Void, Never>] = []

    fileprivate init(
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
        publication: AgenticSettings.Mutations.Publication,
        workers: AgenticSettings.Mutations.Workers,
        pathSettings: @escaping @Sendable () throws -> AgentHost.PathSettings,
        eventSink: AgentHostLocalRunEventSink,
        stateSink: AgentHostLocalRunStateSink
    ) {
        self.id = id
        self.pathSettings = pathSettings
        self.agent = agent
        self.title = title
        self.metadata = metadata
        self.runtime = runtime
        // Reuse a host-supplied history; otherwise install one for this session.
        let sessionHistory = (try? services.require(Sessions.HistoryStore.self))
            ?? Sessions.HistoryStore()
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
        self.publication = publication
        self.workerPublication = workers
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

    func mutationParticipantRuns() -> [UUID: String] {
        participantRuns
    }

    /// A direct Program's workspace in this session: the same leases as a
    /// run, and under coordinated mutations its own participant, so its
    /// changes stage or publish with this session's and join its review.
    func programWorkspace(
        runID: String
    ) async throws -> WorkspaceContext? {
        guard let effective = try accessLeases.expiring().effectiveWorkspace(base: workspace, turnID: runID) else {
            return nil
        }
        let execution: WorkspaceExecution
        switch mutations {
        case .immediate:
            execution = .init(io: io, mutations: .immediate)
        case .coordinated(let coordinator):
            if let retained = mutationParticipantsByRunID[runID] {
                execution = .init(io: io, mutations: .coordinated(retained))
            } else {
                let participant = await coordinator.participant(name: "program:\(id.rawValue):\(runID)")
                let capability: WorkspaceCoordinatedSubmission
                switch publication {
                case .approval:
                    capability = publishing(participant, through: coordinator, run: runID)
                case .review:
                    capability = .init(participant: participant)
                }
                participantIDs.insert(participant.id)
                participantRuns[participant.id] = runID
                mutationParticipantsByRunID[runID] = capability
                execution = .init(io: io, mutations: .coordinated(capability))
            }
        }
        return try accessLeases.context(in: effective, execution: execution)
    }

    /// A settled Program run's staged units, recorded like a run's.
    func settleProgram(runID: String) async {
        await recordStagedMutations(runID: runID)
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
            guard !isOccupied else {
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

        case .queue:
            // Held until the session is free and every earlier queued
            // submission has been admitted; then admitted as usual.
            try await waitForAdmission()
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
        }
    }

    /// Adds `text` to the active run's next model request. Only an
    /// executing run takes steering: a waiting one would carry it past a
    /// decision the operator has not made.
    func steer(_ text: String) async throws {
        guard let runID = currentRunID,
              activeTask != nil,
              currentInteraction == nil,
              let executor = executorsByRunID[runID]
        else {
            await record(.operator_command, "steer → refused: no run is executing")
            throw AgentHost.Local.Failure.notSteerable(id)
        }
        await executor.steer(Message(role: .user, text: text))
        await record(.operator_command, "steer → joins the next model request", run: runID)
    }

    private func carrySteering(from runID: String) async {
        guard let executor = executorsByRunID[runID] else { return }
        undeliveredSteering += await executor.runControl.takeSteering().map(\.content.text)
    }

    private func steeringNote() -> String? {
        guard !undeliveredSteering.isEmpty else { return nil }
        return "[Sent during the previous run, which ended before taking it: "
            + undeliveredSteering.joined(separator: " / ") + "]"
    }

    /// One admission rule for submissions and direct Programs alike.
    private var isOccupied: Bool {
        admissionInProgress
            || currentRunID != nil
            || activeTask != nil
            || finishingRun != nil
            || currentInteraction != nil
            || programRunID != nil
    }

    /// A direct Program takes the session as a run would.
    func beginProgram(_ runID: String) throws {
        guard !isOccupied else {
            throw AgentHost.Local.Failure.sessionBusy(id)
        }
        programRunID = runID
    }

    func endProgram() {
        programRunID = nil
    }

    /// Waits for this submission's turn. Actor reentrancy does not keep
    /// wake-up order, so the ticket order does.
    private func waitForAdmission() async throws {
        let ticket = UUID()
        queuedAdmissions.append(ticket)
        defer { queuedAdmissions.removeAll { $0 == ticket } }
        while isOccupied || queuedAdmissions.first != ticket {
            try Task.checkCancellation()
            await withCheckedContinuation { occupancyWaiters.append($0) }
        }
    }

    private func occupancyChanged() {
        guard !occupancyWaiters.isEmpty else { return }
        let waiters = occupancyWaiters
        occupancyWaiters = []
        waiters.forEach { $0.resume() }
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
        // Notes the model has not seen: workspace changes, and steering a
        // previous run ended before taking.
        let notes = [workspaceNote(), steeringNote()].compactMap { $0 }
        let userMessage = notes.isEmpty
            ? Message(role: .user, text: submission.prompt)
            : Message(
                role: .user,
                content: MessageContent(blocks: notes.map { .text($0) } + [.text(submission.prompt)])
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
        pendingWorkspaceNotes = []
        undeliveredSteering = []
        await traceTurnSettings(.init(
            modelSelection: modelSelection,
            invocationOptions: execution.invocationOptions,
            configuration: configuration,
            available: availableCapabilities,
            visible: visibleCapabilities
        ), run: runID)
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
            try await activateWorkspaceAccess(response, interaction: interaction)
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
    ) async throws {
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

        try await settleLeases(
            accessLeases
                .expiring()
                .activating(
                    lease,
                    baseWorkspace: workspace,
                    turnID: response.sessionID
                ),
            run: response.sessionID
        )
    }

    private func makeExecutor(
        runID: String,
        runConfiguration: AgentHostLocalRunConfiguration
    ) async throws -> AgentExecutor {
        try await settleLeases(accessLeases.expiring(), run: runID)

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
            let workerPublishes = workerPublication == .publish
            let childIO = io
            await delegation.configureChildTooling { session, request, parent in
                // Other sessions are the owner's to read, not a worker's.
                let inherited = parent.using(
                    services: parent.services.removing((any Sessions.CatalogReading).self)
                )
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
                    // A scoped worker writes within its scope at once, so it
                    // can build and test; review follows (keep or roll back).
                    let execution = WorkspaceExecution(
                        io: childIO,
                        mutations: .coordinated(
                            workerPublishes
                                ? await self.publishing(participant, through: coordinator, run: session.id)
                                : WorkspaceCoordinatedSubmission(participant: participant)
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
                    // submissions publish on admission unless the owner
                    // reviews every publication.
                    switch publication {
                    case .approval:
                        capability = publishing(participant, through: coordinator, run: runID)
                    case .review:
                        capability = .init(participant: participant)
                    }
                    participantIDs.insert(participant.id)
                    participantRuns[participant.id] = runID
                    mutationParticipantsByRunID[runID] = capability
                }
                execution = .init(io: io, mutations: .coordinated(capability))
            } else {
                // No workspace: no file mutation capability is available.
                execution = .init(io: io, mutations: .immediate)
            }
        }

        let configuration = runConfiguration.configuration
        if configuration.contextMode == .dynamic {
            await Self.ensureSessionReaders(in: runConfiguration.capabilityState)
        }
        return AgentExecutor(
            model: .init(
                invoker: modelBroker,
                selection: runConfiguration.modelSelection
            ),
            configuration: runConfiguration.configuration,
            tooling: .init(
                registry: runtime.tools,
                workspace: try effectiveWorkspace.map {
                    try accessLeases.context(in: $0, execution: execution)
                },
                catalog: runtime.catalog,
                services: services,
                askRoots: accessLeases.askRoots(for: runID)
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
            ),
            contextServices: configuration.contextMode == .dynamic
                ? .init(
                    resolver: Context.UnmountedResolver(),
                    modelContextLimit: contextLimit(for: runConfiguration),
                    compactions: compactionLedger
                )
                : nil
        )
    }

    /// The routed model's documented input window, when known; otherwise
    /// the configured budget. The policy's own maximum still applies, so a
    /// request is bounded by whichever is smaller: what the model can read
    /// or what the operator chose to spend.
    private func contextLimit(
        for runConfiguration: AgentHostLocalRunConfiguration
    ) -> Int {
        let policy = runConfiguration.configuration.contextPolicy
        let configured = policy.maximumInputTokens + policy.reservedOutputTokens
        guard let window = (try? modelBroker.route(selection: runConfiguration.modelSelection))?
            .route.profile.limits.inputTokens
        else { return configured }
        return window
    }

    private func abandonCoordinatedRun(_ runID: String) async {
        let staged = await pendingSubmissions()
        if let delegation = delegationsByRunID.removeValue(forKey: runID) {
            await delegation.withdrawWorkerMutations()
        }
        if let participant = mutationParticipantsByRunID.removeValue(forKey: runID) {
            try? await participant.close()
        }
        await recordWithdrawn(staged, run: runID)
    }

    /// Pending submissions of this session's participants, root and workers.
    private func pendingSubmissions() async -> [StandardMutationSubmission] {
        guard case .coordinated(let coordinator) = mutations else { return [] }
        let ids = Set(await coordinator.pending_submission_ids(participants: participantIDs))
        return await coordinator.journal().filter { ids.contains($0.id) }
    }

    private func recordStagedMutations(runID: String) async {
        for submission in await pendingSubmissions()
        where recordedStaged.insert(submission.id).inserted {
            _ = try? await log?.append(
                .state(.mutation(.mutation_staged, submission.summary)),
                run: runID
            )
        }
    }

    private func recordWithdrawn(
        _ before: [StandardMutationSubmission],
        run: String?
    ) async {
        let remaining = Set(await pendingSubmissions().map(\.id))
        for submission in before where !remaining.contains(submission.id) {
            _ = try? await log?.append(
                .state(.mutation(.mutation_withdrawn, submission.summary)),
                run: run
            )
        }
    }

    /// Withdraws this session's units among `ids`, releasing their claims.
    func discardStagedMutations(_ ids: [UUID]) async {
        let staged = await pendingSubmissions()
        guard staged.contains(where: { ids.contains($0.id) }) else { return }
        for runID in Set(delegationsByRunID.keys).union(mutationParticipantsByRunID.keys) {
            await abandonCoordinatedRun(runID)
        }
        await recordWithdrawn(staged, run: nil)
    }

    /// Discards just this session's units among `ids`, leaving its other
    /// staged units and its participants as they are.
    func discardReviewedMutations(_ ids: [UUID]) async throws {
        guard case .coordinated(let coordinator) = mutations else { return }
        let staged = await pendingSubmissions()
        let discarded = staged.filter { ids.contains($0.id) }
        guard !discarded.isEmpty else { return }
        try await coordinator.discard(submissions: discarded.map(\.id))
        await recordWithdrawn(staged, run: nil)
    }

    /// How many of `ids` are this session's staged units.
    func stagedUnitCount(among ids: [UUID]) async -> Int {
        await pendingSubmissions().filter { ids.contains($0.id) }.count
    }

    func recordPublication(_ publication: StandardMutationPublication) async {
        guard publication.contributions.contains(where: {
            participantIDs.contains($0.participant_id)
        }) else { return }
        // The owner reviewed it before publishing: nothing left to review.
        await recordPublished(publication, run: nil, reviewed: true)
    }

    /// A publication reached disk: logged, and, unless the owner reviewed
    /// it first, unreviewed until the owner keeps or rolls it back.
    func recordPublished(
        _ publication: StandardMutationPublication,
        run: String?,
        reviewed: Bool = false
    ) async {
        if !reviewed {
            unreviewedPublications.append(publication)
        }
        _ = try? await log?.append(
            .state(.mutation(.mutation_published, publication.summary)),
            run: run
        )
    }

    func recordRolledBack(
        _ publication: StandardMutationPublication
    ) async {
        _ = try? await log?.append(
            .state(.mutation(.mutation_withdrawn, "rolled back: " + publication.summary)),
            run: nil
        )
    }

    /// A participant that publishes each admitted submission at once.
    func publishing(
        _ participant: StandardMutationParticipant,
        through coordinator: StandardMutationCoordinator,
        run runID: String
    ) -> WorkspaceCoordinatedSubmission {
        .init(participant: participant) { [weak self] submission in
            let published = try await coordinator.publish(submissions: [submission])
            if let published {
                await self?.recordPublished(published, run: runID)
            }
            return published
        }
    }

    private func finishTurnAuthority(
        _ runID: String
    ) async {
        runConfigurationsByRunID.removeValue(
            forKey: runID
        )
        try? await settleLeases(
            accessLeases
                .endingTurn(
                    runID
                )
                .expiring(),
            run: runID
        )
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
            await carrySteering(from: runID)
            await abandonCoordinatedRun(runID)
            executorsByRunID.removeValue(forKey: runID)
            await finishTurnAuthority(runID)
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
            await carrySteering(from: runID)
            await abandonCoordinatedRun(runID)
            executorsByRunID.removeValue(forKey: runID)
            await finishTurnAuthority(runID)
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
        await carrySteering(from: runID)
        transcript = result.state.messages.filter { message in
            message.role != .system
        }
        currentInteraction = result.interactionRequest

        if result.isCompleted || result.isFailed || result.isInterrupted {
            // Every settle is a unit boundary. Staged work survives failure
            // and interruption for the owner to publish or discard.
            await recordStagedMutations(runID: runID)
            executorsByRunID.removeValue(
                forKey: runID
            )
            await finishTurnAuthority(
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
                ),
                profile: profile
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

/// Task tools resolve the shared manager and this session's scope. Services
/// the application already supplied win over the Host's defaults.
/// The host's own logs as the session catalog, unless the host supplied
/// one: every session it recorded, readable by the owner's root agent.
func agentHostLocalSessionCatalog(
    _ logs: Run.Log.Store?,
    in services: ToolServices
) throws -> ToolServices {
    guard let logs,
          (try? services.require((any Sessions.CatalogReading).self)) == nil
    else { return services }
    return try services.inserting(logs as any Sessions.CatalogReading)
}

private func agentHostLocalTaskServices(
    _ services: ToolServices,
    tasks: AgentTaskManager?,
    sessionID: AgentHost.Session.ID
) throws -> ToolServices {
    var services = services
    if let tasks,
       (try? services.require(AgentTaskManager.self)) == nil
    {
        services = try services.inserting(tasks)
    }
    if (try? services.require(AgentTaskScope.self)) == nil {
        services = try services.inserting(
            AgentTaskScope(sessionID: sessionID.rawValue)
        )
    }
    return services
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
                preferences: configuration.preferences(for: base.purpose)
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

private extension Run.Event.State {
    static func mutation(_ kind: Kind, _ summary: String) -> Self {
        .init(kind: kind, iteration: 0, summary: summary)
    }
}

private extension StandardMutationSubmission {
    var summary: String {
        let targets = plan.entries.map { $0.target.lastPathComponent }
        let shown = targets.prefix(5).joined(separator: ", ")
        let more = targets.count > 5 ? " +\(targets.count - 5)" : ""
        return "submission \(id) · \(targets.count) entr\(targets.count == 1 ? "y" : "ies"): \(shown)\(more)"
    }
}

private extension StandardMutationPublication {
    var summary: String {
        "publication \(result.id) · \(result.status.rawValue) · "
            + "\(result.applied.count) applied · submissions \(submission_ids.count) · "
            + (result.rollback == nil ? "no rollback" : "rollback available")
    }
}
