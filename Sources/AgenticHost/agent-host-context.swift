import Agentic
import AgenticSessions
import AgenticContextWindow
import AgenticRuntime

public extension AgentHost {
    /// What `compact` did: the compaction recorded, or nil when nothing
    /// older was large enough to compact.
    struct CompactionResult: Sendable, Hashable {
        public var compaction: ContextWindow.Compaction?
        public var outcome: String
    }
}

extension AgentHostLocalSessionState {
    func compact() async throws -> AgentHost.CompactionResult {
        do {
            guard !isExecuting else {
                throw AgentHost.Local.Failure.compactionWhileExecuting
            }
            let done = await compactionLedger.compactions
            guard let compaction = ContextWindow.Compactor.plan(messages: transcriptMessages, excluding: done) else {
                let outcome = "nothing to compact: the two newest turns stay whole and older results are small or compacted"
                await record(.operator_command, ":compact → \(outcome)")
                return .init(compaction: nil, outcome: outcome)
            }
            await compactionLedger.record(compaction)
            let outcome = "\(compaction.pointers.count) result\(compaction.pointers.count == 1 ? "" : "s") "
                + "now pointers to their preserved copies, ≈\(compaction.estimatedTokensSaved) tokens; "
                + "the next request misses the cache once"
            await record(.context_changed, "compacted: " + compaction.pointers.map { "\($0.call.name) \($0.call.id)" }.joined(separator: ", "))
            await record(.operator_command, ":compact → \(outcome)")
            return .init(compaction: compaction, outcome: outcome)
        } catch {
            await record(.operator_command, ":compact → refused: \(error.localizedDescription)")
            throw error
        }
    }
}
