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
        ) async throws -> AgentRunner.Result

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
        ) async throws -> AgentRunner.Result

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
    }
}
