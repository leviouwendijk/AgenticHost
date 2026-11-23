import Agentic
import AgenticPresentation
import Foundation

/// `:` commands typed in one conversation, dispatched by their catalog
/// chapter. Every interface runs them here, so a command means the same in
/// the terminal and in the app.
public extension AgenticConversationWork {
    /// What a command leaves for the interface; everything else (transcript
    /// notes, activity, started work) has happened in the engine.
    enum CommandOutcome: Sendable {
        case done
        /// `:review` found staged changes: open them for decision.
        case reviewRequested
        /// The command started an operation (`:program`, `:publish`,
        /// `:discard`); its submission when it carries one.
        case started(AgenticConversationSubmission?)
    }

    /// Runs `command` (the text after `:`) in this conversation.
    func runCommand(
        _ command: String
    ) async throws -> CommandOutcome {
        let running = snapshot().isRunning
        switch AgenticConsoleCommands.catalog.definition(for: command)?.chapter {
        case .workspace:
            await conversation.runWorkspaceCommand(command)
            return .done
        case .run:
            await runControlCommand(command, running: running)
            return .done
        case .capabilities:
            return try await runCapabilityCommand(command, running: running)
        case .review:
            return try await runStagedCommand(":" + command, running: running)
        case .context:
            await conversation.runContextCommand(command)
            return .done
        case .results:
            await conversation.runExportCommand(command)
            return .done
        case nil:
            await conversation.noteCommand(command, outcome: "refused: unknown command")
            return .done
        }
    }
}

private extension AgenticConversationWork {
    /// `:interrupt` and `:queue`.
    func runControlCommand(
        _ text: String,
        running: Bool
    ) async {
        await conversation.beginCommand()
        let outcome: String
        do {
            switch try AgenticControlCommand(parsing: text) {
            case .interrupt(let mode):
                guard running else {
                    outcome = "no active run to interrupt"
                    break
                }
                try await interrupt(
                    mode: mode,
                    reason: "Interrupted with :\(text)."
                )
                outcome = mode == .urgent
                    ? "stopping at the earliest safe boundary"
                    : "stopping after the current iteration"
            case .queue(let policy?):
                await conversation.setQueuePolicy(policy)
                outcome = "messages sent during a run: \(policy.pendingLabel.replacingOccurrences(of: "pending · ", with: ""))"
            case .queueClear:
                let cancelled = cancelAll()
                await conversation.withdrawPending(cancelled)
                outcome = cancelled.isEmpty
                    ? "no messages queued"
                    : "\(cancelled.count) queued message\(cancelled.count == 1 ? "" : "s") cancelled · text back in the message box"
            case .queue(nil):
                let policy = await conversation.presentationSnapshot().queuePolicy
                let held = queuedSubmissions().count
                outcome = ":queue \(policy.rawValue) · \(policy.pendingLabel.replacingOccurrences(of: "pending · ", with: ""))"
                    + (held > 0 ? " · \(held) queued" : "")
            }
        } catch {
            outcome = "refused: \(error.localizedDescription)"
        }
        await conversation.noteCommand(text, outcome: outcome)
        await conversation.setActivity(outcome)
    }

    /// `:program` and `:inference`: an installed capability, with the same
    /// contracts as a model's call.
    func runCapabilityCommand(
        _ text: String,
        running: Bool
    ) async throws -> CommandOutcome {
        await conversation.beginCommand()
        let command: AgenticCapabilityCommand
        do {
            command = try AgenticCapabilityCommand(parsing: text)
        } catch {
            await conversation.noteCommand(text, outcome: "refused: \(error.localizedDescription)")
            return .done
        }
        switch command {
        case .program(let invocation):
            guard !running else {
                await conversation.noteCommand(text, outcome: "refused: the conversation is busy; try again when it settles")
                return .done
            }
            let snapshot = await conversation.presentationSnapshot()
            let submission = AgenticConversationSubmission(
                body: ":" + text,
                contents: [],
                preferredModelProfileID: snapshot.preferredModelProfileID,
                instructionIDs: snapshot.selectedInstructionIDs,
                availableCapabilities: snapshot.availableCapabilities,
                visibleCapabilities: snapshot.visibleCapabilities,
                autonomyMode: snapshot.selectedAutonomyMode
            )
            await conversation.setActivity("invoking program")
            try start(.program(invocation, submission))
            return .started(submission)
        case .inference(let identifier, let input):
            // A model call: it reports into the transcript when done.
            await conversation.setActivity("invoking inference \(identifier.rawValue)")
            let conversation = conversation
            Task { await conversation.runInference(text, identifier: identifier, input: input) }
            return .done
        }
    }

    /// `:review`, `:publish` and `:discard` on this conversation's staged changes.
    func runStagedCommand(
        _ command: String,
        running: Bool
    ) async throws -> CommandOutcome {
        guard !running else {
            await conversation.setActivity("Staged changes are reviewable once the current run settles.")
            return .done
        }
        guard let staged = await conversation.stagedReview() else {
            await conversation.setActivity("No staged changes to review.")
            return .done
        }
        switch command {
        case ":review":
            return .reviewRequested
        case ":publish", ":discard":
            // Every staged unit at once; the review menu decides them one by one.
            try start(
                .action(
                    interruptionID: AgenticConversationSession.wholeStagedReviewID(of: staged.id),
                    runID: staged.runID,
                    stepID: staged.stepID,
                    action: command == ":publish" ? .publish : .discard
                )
            )
            return .started(nil)
        default:
            return .done
        }
    }
}
