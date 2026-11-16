import Agentic
import AgenticContext
import AgenticRuntime
import TestFlows
@testable import AgenticTUI

extension AgentHostLocalFlowTesting {
    /// A `context_changed` event becomes one Changes card, placed before
    /// the answer of the request it shaped, and reported once.
    static func runConversationChangeProjection() async throws -> [TestDiagnostic] {
        let event = Run.Event.State(
            kind: .context_changed,
            iteration: 1,
            summary: "1 budget_result, 1 repeated_result",
            contextChanges: [
                .init(messageID: "tool.2", reason: .budget_result,
                      call: .init(id: "read.2", name: "read_file")),
                .init(messageID: "tool.3", reason: .repeated_result,
                      call: .init(id: "read.3", name: "read_file"),
                      sourceCall: .init(id: "read.1", name: "read_file")),
            ]
        )
        let change = AgenticConversationChangeProjection.change(event, runID: "run-1")
        try Expect.equal(change.kind, .context, "a history change is a context change")
        try Expect.equal(change.iteration, 2, "iterations count from one")
        try Expect.true(change.isLossy, "a shortened result loses content")
        try Expect.equal(
            change.items.map(\.subject),
            ["read_file · read.2", "read_file · read.3"],
            "each item names its call"
        )
        try Expect.equal(change.items[1].detail, "→ see read.1", "a pointer names its original")
        try Expect.equal(change.items[1].isRecoverable, true, "a pointed result is still in view")

        let pointerOnly = AgenticConversationChangeProjection.change(
            Run.Event.State(
                kind: .context_changed, iteration: 0, summary: "",
                contextChanges: [.init(messageID: "t", reason: .repeated_result)]
            ),
            runID: "run-1"
        )
        try Expect.true(!pointerOnly.isLossy, "a pointer to content still in view is not lossy")
        try Expect.equal(pointerOnly.summary, "1 × repeat pointed at its original", "one reason, one label")
        return [.field("summary", change.summary)]
    }
}
