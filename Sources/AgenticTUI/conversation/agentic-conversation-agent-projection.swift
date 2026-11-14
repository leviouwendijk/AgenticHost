import Agentic
import AgenticInterfaces
import AgenticRuntime

/// A run's delegation tree for its run card: the root Agent, then each
/// worker under the Agent that delegated to it.
package enum AgenticConversationAgentProjection {
    package static func project(
        _ workers: [AgentDelegation.Snapshot],
        runID: String,
        runState: AgenticHostConsoleRunState
    ) -> [AgenticHostConsoleAgentPresentation] {
        guard let root = workers.first(where: { $0.session.id == runID }) else {
            return []
        }
        let children = Dictionary(grouping: workers.filter { $0.session.parentSessionID != nil }) {
            $0.session.parentSessionID!
        }

        func hasUnsettledDescendants(_ id: String) -> Bool {
            (children[id] ?? []).contains { !$0.settled || hasUnsettledDescendants($0.session.id) }
        }

        func visit(
            _ worker: AgentDelegation.Snapshot,
            depth: Int
        ) -> [AgenticHostConsoleAgentPresentation] {
            let id = worker.session.id
            let waiting = hasUnsettledDescendants(id)
            let state = worker.session.parentSessionID == nil
                ? rootState(runState, waiting: waiting)
                : workerState(worker, waiting: waiting)
            let agent = AgenticHostConsoleAgentPresentation(
                id: id,
                parentID: worker.session.parentSessionID,
                depth: depth,
                title: title(worker.session.agent),
                state: state,
                detail: worker.requestedScope
            )
            let ordered = (children[id] ?? []).sorted { $0.session.id < $1.session.id }
            return [agent] + ordered.flatMap { visit($0, depth: depth + 1) }
        }

        return visit(root, depth: 0)
    }

    /// The last segment of `domain.agents.name`.
    static func title(
        _ agent: AgentIdentifier
    ) -> String {
        agent.rawValue.split(separator: ".").last.map(String.init) ?? agent.rawValue
    }

    /// The root's state is its run's; while workers are unsettled it is
    /// suspended on them, whatever its last published phase says.
    static func rootState(
        _ state: AgenticHostConsoleRunState,
        waiting: Bool
    ) -> AgenticHostConsoleAgentState {
        switch state {
        case .completed: return .completed
        case .failed: return .failed
        case .interrupted: return .interrupted
        case _ where waiting: return .waiting
        case .active: return .running
        case .awaitingApproval, .onHold: return .awaitingReview
        case .ready, .pause_pending, .paused: return .queued
        }
    }

    static func workerState(
        _ worker: AgentDelegation.Snapshot,
        waiting: Bool
    ) -> AgenticHostConsoleAgentState {
        if worker.executing {
            return .running
        }
        switch worker.phase {
        case .completed?: return .completed
        case .failed?: return .failed
        case .interrupted?: return .interrupted
        case _ where worker.settled: return .completed
        case _ where waiting: return .waiting
        case .awaiting_approval?: return .awaitingReview
        case .suspended?: return .awaitingInput
        case .ready_for_model?, .receiving_model_response?, .processing_tool_calls?, nil: return .queued
        }
    }
}
