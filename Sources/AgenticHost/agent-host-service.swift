import Agentic
import AgenticModels
import AgenticRuntime

public extension AgentHost {
    protocol Service:
        Sendable
    {
        func sessions() async throws
            -> [Session.Summary]

        func start(
            _ request: Session.Start
        ) async throws -> Session.Summary

        func submit(
            _ submission: Session.Submission
        ) async throws -> AgentRunResult

        func observe(
            _ session: Session.ID
        ) -> AsyncThrowingStream<AgentRunEvent, Error>

        func observeState(
            _ session: Session.ID
        ) -> AsyncThrowingStream<AgentRunStateSnapshot, Error>

        func resume(
            _ response: AgentInteraction.Response
        ) async throws -> AgentRunResult

        func cancel(
            _ session: Session.ID
        ) async throws

        func transcript(
            _ session: Session.ID
        ) async throws -> Transcript

        func models() async throws
            -> [AgentModelProfile]
    }
}
