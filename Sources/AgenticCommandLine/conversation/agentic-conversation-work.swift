import Agentic
import AgenticRuntime
import AgenticInterfaces
import Foundation

/// One conversation's in-flight operations. A view may be detached while its
/// work continues; only an explicit runtime interruption stops an active run.
package actor AgenticConversationWork {
    package enum Operation: Sendable {
        case submission(AgenticConversationSubmission)
        case supersedingSubmission(
            AgenticConversationSubmission,
            expectedRunID: String?
        )
        case program(AgenticConversationProgramInvocation, AgenticConversationSubmission)
        case userInput(interactionID: String, runID: String, reply: UserInputReply)
        case action(interruptionID: String, runID: String, stepID: String, action: AgenticHostConsoleAction)
    }

    package enum Failure: Error {
        case busy
    }

    package struct Snapshot: Sendable, Equatable {
        package let generation: Int
        package let completedGeneration: Int
        package let isRunning: Bool
        /// An invocation error, not the result status of an Agent run.
        package let lastError: String?
    }

    package let conversation: AgenticConversationSession
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var supersedingGeneration: Int?
    private var generation = 0
    private var completedGeneration = 0
    private var lastError: String?

    package init(conversation: AgenticConversationSession) {
        self.conversation = conversation
    }

    /// Returns after scheduling, not after the Agent operation completes.
    /// Rejects a second operation in this conversation without affecting work
    /// belonging to any other conversation.
    @discardableResult
    package func start(_ operation: Operation) throws -> Int {
        // A confirmed supersession is allowed while the previous model
        // submission is still settling: the Host owns the interruption and
        // serializes actual run ownership. The activeTask handle moves to the
        // newest operation so interface busy-tracking follows it.
        let isSuperseding: Bool
        if case .supersedingSubmission = operation {
            isSuperseding = true
        } else {
            isSuperseding = false
        }
        guard tasks.isEmpty || (isSuperseding && tasks.count == 1 && supersedingGeneration == nil) else {
            throw Failure.busy
        }

        generation += 1
        let currentGeneration = generation
        if isSuperseding { supersedingGeneration = currentGeneration }
        lastError = nil
        tasks[currentGeneration] = Task { [conversation] in
            do {
                switch operation {
                case .submission(let submission):
                    _ = try await conversation.submit(submission)
                case .supersedingSubmission(let submission, let expectedRunID):
                    _ = try await conversation.submit(
                        submission,
                        existingRunPolicy:
                            .supersede(expectedRunID: expectedRunID)
                    )
                case .program(let invocation, let submission):
                    _ = try await conversation.invokeProgram(
                        invocation,
                        submission: submission
                    )
                case .userInput(let interactionID, let runID, let reply):
                    try await conversation.resolveUserInput(
                        interactionID: interactionID,
                        runID: runID,
                        reply: reply
                    )
                case .action(let interruptionID, let runID, let stepID, let action):
                    try await conversation.resolveConversationAction(
                        interruptionID: interruptionID,
                        runID: runID,
                        stepID: stepID,
                        action: action
                    )
                }
                self.finish(generation: currentGeneration, error: nil)
            } catch {
                // submit() already owns rollback and its error presentation;
                // an older operation must never mark a newer run failed.
                if !(error is CancellationError) {
                    switch operation {
                    case .submission, .supersedingSubmission:
                        break
                    default:
                        await conversation.recordFailure(error)
                    }
                }
                self.finish(
                    generation: currentGeneration,
                    error: error.localizedDescription
                )
            }
        }
        return currentGeneration
    }

    package func snapshot() -> Snapshot {
        .init(
            generation: generation,
            completedGeneration: completedGeneration,
            isRunning: !tasks.isEmpty,
            lastError: lastError
        )
    }

    /// Join the current operation without owning or cancelling it.
    package func waitUntilIdle() async {
        while !tasks.isEmpty {
            for task in Array(tasks.values) {
                await task.value
            }
        }
    }

    /// Runtime interruption preserves checkpoints; never cancel activeTask
    /// as a substitute for a model-run interruption.
    package func interrupt(
        runID: String? = nil,
        mode: Run.Interruption.Mode,
        reason: String? = nil
    ) async throws {
        try await conversation.interruptRun(
            runID: runID,
            mode: mode,
            reason: reason
        )
    }

    private func finish(generation finished: Int, error: String?) {
        tasks.removeValue(forKey: finished)
        if supersedingGeneration == finished { supersedingGeneration = nil }
        guard generation == finished else { return }
        completedGeneration = finished
        lastError = error
    }

}
