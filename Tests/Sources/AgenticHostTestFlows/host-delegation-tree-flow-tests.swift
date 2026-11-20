import Agentic
import AgenticInterfaces
import AgenticRuntime
@_spi(Testing) import AgenticTUI
import TestFlows

extension AgenticRuntimeHostProjectionFlowTesting {
    /// The run card's delegation tree: the root under its run, workers under
    /// the Agent that delegated to them, each with its own state.
    static func runDelegationTree() throws -> [TestDiagnostic] {
        func worker(
            _ id: String,
            _ agent: String,
            parent: String?,
            depth: Int,
            phase: AgentExecutor.Phase? = nil,
            executing: Bool = false,
            settled: Bool = false
        ) -> AgentDelegation.Snapshot {
            .init(
                session: .init(id: id, agent: .init(rawValue: agent), parentSessionID: parent, depth: depth),
                phase: phase,
                requestedScope: parent == nil ? nil : "scope of \(id)",
                executing: executing,
                settled: settled
            )
        }
        let workers = [
            worker("w2", "swift_lang.agents.tester", parent: "run", depth: 1, phase: .completed, settled: true),
            worker("run", "swift_lang.agents.orchestrator", parent: nil, depth: 0, phase: .suspended),
            worker("w1", "swift_lang.agents.implementer", parent: "run", depth: 1, phase: .suspended),
            worker("w1a", "swift_lang.agents.reviewer", parent: "w1", depth: 2, phase: .awaiting_approval),
            worker("other", "swift_lang.agents.orchestrator", parent: nil, depth: 0),
        ]

        let agents = AgenticConversationAgentProjection.project(
            workers,
            runID: "run",
            runState: .awaitingApproval
        )
        try Expect.equal(agents.map(\.id), ["run", "w1", "w1a", "w2"], "Parents precede their workers; other runs are excluded")
        try Expect.equal(agents.map(\.title), ["orchestrator", "implementer", "reviewer", "tester"], "Agents show their name")
        try Expect.equal(
            agents.map(\.state),
            [.waiting, .waiting, .awaitingReview, .completed],
            "The review sits with the worker that raised it; its ancestors wait"
        )

        var resumed = workers
        resumed[3] = worker("w1a", "swift_lang.agents.reviewer", parent: "w1", depth: 2, phase: .awaiting_approval, executing: true)
        try Expect.equal(
            AgenticConversationAgentProjection.project(resumed, runID: "run", runState: .awaitingApproval)[2].state,
            .running,
            "An executing worker is running whatever its last phase"
        )

        try Expect.equal(
            AgenticConversationAgentProjection.project(workers, runID: "run", runState: .completed)[0].state,
            .completed,
            "A settled run's root shows its outcome"
        )

        let billed = AgentCostRecord(
            model: "hyai/auto",
            turns: [
                .init(turnIndex: 0, requestModel: "hyai/auto"),
                .init(
                    turnIndex: 1,
                    requestModel: "hyai/auto",
                    actual: .init(
                        status: .available,
                        confidence: .providerReported,
                        usage: .init(inputTokens: 10),
                        metadata: ["model": "deepseek-v4-flash"]
                    )
                ),
            ]
        )
        try Expect.equal(
            AgenticConversationAgentProjection.model(billed),
            "deepseek-v4-flash",
            "An Agent shows the model that answered its latest turn, not the route it asked for"
        )
        try Expect.equal(
            AgenticConversationAgentProjection.project(workers, runID: "run", runState: .active, rootCost: billed)[0].model,
            "deepseek-v4-flash",
            "The root shows its own model"
        )
        return []
    }
}
