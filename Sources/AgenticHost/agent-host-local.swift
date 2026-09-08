import Agentic
import AgenticExecution
import AgenticModels
import AgenticRuntime
import AgenticWorkspace
import Foundation

public extension AgentHost {
    actor Local: Service {
        public let runtime: AgenticRuntime
        public let workspace: AgentWorkspace?

        private var sessionsByID: [Session.ID: AgentHostLocalSessionState]
        private var sessionOrder: [Session.ID]
        private var runOwners: [String: Session.ID]
        private nonisolated let eventHub: AgentHostLocalEventHub

        public init(
            runtime: AgenticRuntime,
            workspace: AgentWorkspace? = nil
        ) {
            self.runtime = runtime
            self.workspace = workspace
            self.sessionsByID = [:]
            self.sessionOrder = []
            self.runOwners = [:]
            self.eventHub = .init()
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

            let state = AgentHostLocalSessionState(
                id: sessionID,
                title: request.title,
                metadata: request.metadata,
                runtime: runtime,
                workspace: workspace,
                eventSink: .init(
                    session: sessionID,
                    hub: eventHub
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

        public func models() async throws -> [AgentModelProfile] {
            agentHostLocalProfiles(
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
    }
}

public extension AgentHost.Local {
    enum Failure:
        Swift.Error,
        LocalizedError,
        Sendable
    {
        case duplicateSession(AgentHost.Session.ID)
        case sessionNotFound(AgentHost.Session.ID)
        case noModelProfiles
        case sessionBusy(AgentHost.Session.ID)
        case runNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .duplicateSession(let session):
                return "AgentHost.Local session '\(session.rawValue)' already exists."

            case .sessionNotFound(let session):
                return "AgentHost.Local session '\(session.rawValue)' was not found."

            case .noModelProfiles:
                return "AgentHost.Local cannot submit without at least one realized model profile."

            case .sessionBusy(let session):
                return "AgentHost.Local session '\(session.rawValue)' already has an active or suspended run."

            case .runNotFound(let runID):
                return "AgentHost.Local runtime run '\(runID)' was not found."
            }
        }
    }
}

private actor AgentHostLocalSessionState {
    private let id: AgentHost.Session.ID
    private let title: String?
    private let metadata: [String: String]
    private let runtime: AgenticRuntime
    private let workspace: AgentWorkspace?
    private let historyStore: AgentHostLocalHistoryStore
    private let eventSink: AgentHostLocalRunEventSink

    private var transcript: [AgentMessage]
    private var nextOrdinal: Int
    private var runnersByRunID: [String: AgentRunner]
    private var activeTask: Task<AgentRunResult, Error>?
    private var currentRunID: String?
    private var currentInteraction: AgentInteraction.Request?

    init(
        id: AgentHost.Session.ID,
        title: String?,
        metadata: [String: String],
        runtime: AgenticRuntime,
        workspace: AgentWorkspace?,
        eventSink: AgentHostLocalRunEventSink
    ) {
        self.id = id
        self.title = title
        self.metadata = metadata
        self.runtime = runtime
        self.workspace = workspace
        self.historyStore = .init()
        self.eventSink = eventSink
        self.transcript = []
        self.nextOrdinal = 1
        self.runnersByRunID = [:]
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

        // Local is intentionally lifecycle-only. It does not synthesize a
        // program/system prompt or reinterpret adapter stop/tool-loop behavior;
        // AgenticPrograms can compose those concerns above this boundary.
        guard let profile = agentHostLocalProfiles(runtime).first else {
            throw AgentHost.Local.Failure.noModelProfiles
        }
        let adapter = try runtime.adapters.adapter(
            for: profile.adapterIdentifier
        )

        let runID = "\(id.rawValue)-turn-\(nextOrdinal)"
        nextOrdinal += 1

        let userMessage = AgentMessage(
            role: .user,
            text: submission.prompt
        )
        transcript.append(
            userMessage
        )

        var requestMetadata = submission.metadata
        requestMetadata["agent_host_session_id"] = id.rawValue
        requestMetadata["agent_host_run_id"] = runID
        requestMetadata["model_profile_id"] = profile.identifier.rawValue

        let request = AgentRequest(
            model: profile.model,
            messages: transcript,
            metadata: requestMetadata
        )
        let runner = AgentRunner(
            adapter: adapter,
            configuration: .init(
                maximumIterations: 12,
                historyPersistenceMode: .checkpointmutation
            ),
            toolRegistry: runtime.tools,
            workspace: workspace,
            historyStore: historyStore,
            eventSinks: [
                eventSink,
            ]
        )
        runnersByRunID[runID] = runner
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
              let runner = runnersByRunID[response.sessionID]
        else {
            throw AgentHost.Local.Failure.runNotFound(
                response.sessionID
            )
        }

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
            let result = try await task.value
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
