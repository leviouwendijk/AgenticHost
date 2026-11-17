import Agentic
import AgenticModels
import AgenticRuntime
import Foundation
import Writers

public extension AgentHost {
    protocol Service:
        Sendable
    {
        func sessions() async throws
            -> [Session.Summary]

        func delegatedSessions(
            _ session: Session.ID
        ) async throws -> [AgentDelegation.Session]

        func delegatedWorkers(
            _ session: Session.ID
        ) async throws -> [AgentDelegation.Snapshot]

        /// Owner-only controls, never installed as model-facing tools.
        func interruptWorker(
            _ session: Session.ID,
            workerID: String,
            mode: Run.Interruption.Mode,
            reason: String?
        ) async throws -> AgentExecutor.Result?

        func resumeWorker(
            _ session: Session.ID,
            workerID: String,
            resolution: Run.Interaction.Resolution
        ) async throws -> AgentExecutor.Result

        func continueAfterWorkerInterruption(
            _ session: Session.ID,
            workerID: String
        ) async throws -> AgentExecutor.Result

        func withdrawWorkerMutations(
            _ session: Session.ID,
            workerID: String
        ) async throws

        /// Read-only, exact staged aggregate of one session's units, or of
        /// every idle session's; only the owner can approve it.
        /// With `includingPublished`, also the changes already written and
        /// not yet reviewed: keep (approve) or roll back (deny).
        func reviewCoordinatedMutations(
            session: Session.ID?,
            includingPublished: Bool
        ) async throws -> CoordinatedMutationReview?

        func publishCoordinatedMutations(
            reviewID: UUID,
            decision: ApprovalDecision
        ) async throws -> StandardMutationPublication?

        /// Decides each reviewed submission on its own: approved ones
        /// publish, denied ones are discarded, and the rest stay staged.
        func decideCoordinatedMutations(
            reviewID: UUID,
            decisions: [UUID: ApprovalDecision]
        ) async throws -> StandardMutationPublication?

        /// The session's workspace: configured roots, the roots and
        /// restrictions added on top, and the working directory.
        func workspace(
            _ session: Session.ID
        ) async throws -> WorkspaceState

        /// Owner-only, never a model-facing tool. Traced in the session log
        /// with `command` as typed; the model is told on its next turn.
        func changeWorkspace(
            _ session: Session.ID,
            _ change: WorkspaceChange,
            command: String
        ) async throws -> WorkspaceChangeResult

        /// What the Host has traced for the operator in this session
        /// (`operator_command`, `workspace_changed`), from `index` on.
        func operatorTrace(
            _ session: Session.ID,
            from index: Int
        ) async throws -> [OperatorTraceEntry]

        /// Owner-only, traced: replaces older tool results with pointers to
        /// their preserved copies for every later request (one cache miss,
        /// then a stable prefix). Refused while a run is executing.
        func compact(
            _ session: Session.ID
        ) async throws -> CompactionResult

        /// Changes written to disk in this session and not yet reviewed.
        func unreviewedChanges(
            _ session: Session.ID
        ) async throws -> Int

        /// Adds `text` to the executing run's next model request. Owner-only
        /// and traced; refused unless a run is executing. Steering a run
        /// ends before taking opens the session's next turn.
        func steer(
            _ session: Session.ID,
            text: String
        ) async throws

        func start(
            _ request: Session.Start
        ) async throws -> Session.Summary

        func submit(
            _ submission: Session.Submission
        ) async throws -> AgentExecutor.Result

        func invokeProgram(
            _ invocation: ProgramInvocation
        ) async throws -> ProgramExecutionRecord

        /// Owner-only: an installed Inference with JSON input, routed with
        /// the application's executor binding and the default adapter.
        func invokeInference(
            _ request: InferenceInvocationRequest
        ) async throws -> InferenceInvocationResult

        func resumeProgram(
            _ response: Run.Interaction.Response
        ) async throws -> ProgramExecutionRecord

        func observe(
            _ session: Session.ID
        ) -> AsyncThrowingStream<Run.Event.State, Error>

        func observeState(
            _ session: Session.ID
        ) -> AsyncThrowingStream<AgentRunStateSnapshot, Error>

        func resume(
            _ response: Run.Interaction.Response
        ) async throws -> AgentExecutor.Result

        func interrupt(
            _ interruption: Session.Interruption
        ) async throws

        func cancel(
            _ session: Session.ID
        ) async throws

        func transcript(
            _ session: Session.ID
        ) async throws -> Transcript

        func capabilities() async throws
            -> Capabilities

        /// Resolve a new conversation's effective model without invocation.
        /// This route uses the same configuration and broker as execution.
        func resolveModel(
            for agent: AgentIdentifier?
        ) async throws -> AgentModelRouteResult
    }
}

public extension AgentHost.Service {
    /// Every idle session's staged units.
    func reviewCoordinatedMutations() async throws -> AgentHost.CoordinatedMutationReview? {
        try await reviewCoordinatedMutations(session: nil, includingPublished: true)
    }

    func reviewCoordinatedMutations(
        session: AgentHost.Session.ID?
    ) async throws -> AgentHost.CoordinatedMutationReview? {
        try await reviewCoordinatedMutations(session: session, includingPublished: true)
    }
}
