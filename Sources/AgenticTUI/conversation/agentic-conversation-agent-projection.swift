import Agentic
import AgenticInterfaces
import AgenticRuntime

/// A run's delegation tree for its run card: the root Agent, then each
/// worker under the Agent that delegated to it.
@_spi(Testing) public enum AgenticConversationAgentProjection {
    public static func project(
        _ workers: [AgentDelegation.Snapshot],
        runID: String,
        runState: AgenticHostConsoleRunState,
        rootState: AgentRunStateSnapshot? = nil,
        rootCost: AgentCostRecord? = nil
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
                ? rootAgentState(runState, waiting: waiting)
                : workerState(worker, waiting: waiting)
            let isRoot = worker.session.parentSessionID == nil
            let live = isRoot ? rootState : worker.state
            let cost = isRoot ? rootCost ?? rootState?.costRecord : worker.state?.costRecord
            let agent = AgenticHostConsoleAgentPresentation(
                id: id,
                parentID: worker.session.parentSessionID,
                depth: depth,
                title: title(worker.session.agent),
                state: state,
                detail: worker.requestedScope,
                model: model(cost),
                iteration: live?.state.iteration,
                iterationLimit: live?.runLimits.iterations,
                cost: costDescription(cost)
            )
            let ordered = (children[id] ?? []).sorted { $0.session.id < $1.session.id }
            return [agent] + ordered.flatMap { visit($0, depth: depth + 1) }
        }

        return visit(root, depth: 0)
    }

    /// The model that answered the latest turn: the billed one when the
    /// route was virtual, e.g. `auto`, else the one requested.
    public static func model(
        _ record: AgentCostRecord?
    ) -> String? {
        guard let record else { return nil }
        let turn = record.turns.max { $0.turnIndex < $1.turnIndex }
        return turn?.actual?.metadata["model"] ?? turn?.requestModel ?? record.model
    }

    static func costDescription(
        _ record: AgentCostRecord?
    ) -> String? {
        guard let record else { return nil }
        let usage = AgenticConversationUsagePresentation(records: [record.id: record])
        return usage.amounts.isEmpty ? nil : usage.costDescription
    }

    /// The last segment of `domain.agents.name`.
    static func title(
        _ agent: AgentIdentifier
    ) -> String {
        agent.rawValue.split(separator: ".").last.map(String.init) ?? agent.rawValue
    }

    /// The root's state is its run's; while workers are unsettled it is
    /// suspended on them, whatever its last published phase says.
    static func rootAgentState(
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
