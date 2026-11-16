import Agentic
import AgenticContext
import AgenticInterfaces
import AgenticRuntime

/// Run events that changed what a run works with, as Changes cards.
enum AgenticConversationChangeProjection {
    /// A `context_changed` event: what one request carried less of.
    static func change(
        _ event: Run.Event.State,
        runID: String
    ) -> AgenticChangePresentation {
        let changes = event.contextChanges ?? []
        let reasons = Set(changes.map(\.reason))
        let summary: String
        if reasons.count == 1, let reason = reasons.first {
            summary = "\(changes.count) × \(label(reason))"
        } else {
            summary = "\(changes.count) items shortened or left out"
        }
        return .init(
            id: event.id,
            kind: .context,
            runID: runID,
            iteration: event.iteration + 1,
            summary: summary,
            reason: reasons.count == 1
                ? AgenticChangePresentation.contextReason(reasons.first!.rawValue)
                : "the request was fitted to the history budget",
            items: changes.enumerated().map { index, change in
                .init(
                    id: "\(event.id)-\(index)",
                    subject: change.call.map { "\($0.name) · \($0.id)" } ?? "message \(change.messageID)",
                    detail: change.sourceCall.map { "→ see \($0.id)" }
                        ?? AgenticChangePresentation.contextReason(change.reason.rawValue),
                    // A pointer names a result still in view; other content
                    // is in the session log, readable only with a reader.
                    isRecoverable: change.reason == .repeated_result ? true : nil
                )
            },
            isLossy: !reasons.isSubset(of: [.repeated_result])
        )
    }

    static func label(
        _ reason: Context.HistorySelection.Change.Reason
    ) -> String {
        switch reason {
        case .aged_result: "aged result shortened"
        case .budget_result: "result shortened"
        case .unseen_result: "unread result shortened"
        case .repeated_result: "repeat pointed at its original"
        case .turn_budget: "earlier turn left out"
        case .exchange_budget: "tool exchange left out"
        case .working_set: "outside the working set"
        }
    }
}
