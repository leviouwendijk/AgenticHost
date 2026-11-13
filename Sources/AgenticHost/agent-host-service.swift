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

        /// Read-only, exact staged aggregate; only the owner can approve it.
        func reviewCoordinatedMutations() async throws
            -> CoordinatedMutationReview?

        func publishCoordinatedMutations(
            reviewID: UUID,
            decision: ApprovalDecision
        ) async throws -> StandardMutationPublication?

        func start(
            _ request: Session.Start
        ) async throws -> Session.Summary

        func submit(
            _ submission: Session.Submission
        ) async throws -> AgentExecutor.Result

        func invokeProgram(
            _ invocation: ProgramInvocation
        ) async throws -> ProgramExecutionRecord

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
