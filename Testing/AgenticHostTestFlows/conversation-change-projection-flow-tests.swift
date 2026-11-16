import Agentic
import AgenticContext
import AgenticRuntime
@testable import AgenticHost
import Foundation
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
        let change = AgenticConversationChangeProjection.change(event, runID: "run-1")!
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
        )!
        try Expect.true(!pointerOnly.isLossy, "a pointer to content still in view is not lossy")
        try Expect.equal(pointerOnly.summary, "1 × repeat pointed at its original", "one reason, one label")
        // With context management on, the session readers are enabled and
        // visible whatever the agent declared: pointers stay readable.
        let history = Sessions.Tools.History.definition.identifier
        let state = AgentCapabilityState(
            installed: .init(tools: [history, "other_tool"]),
            available: AgentCapabilitySet.none,
            visible: AgentCapabilitySet.none
        )
        await AgentHostLocalSessionState.ensureSessionReaders(in: state)
        try Expect.equal(await state.visible.tools, [history], "only installed readers, enabled and visible")

        // :compact with nothing old enough: an honest outcome, traced.
        let gateway = GatewayFlowScriptedModelGateway(bufferedResponses: [])
        let host = AgentHost.Local(
            runtime: try await AgenticRuntime(application: Agentic.application("compact-fixture") {
                modelProvider(AgentHostLocalModelProvider(modelGateway: gateway))
            })
        )
        let conversation = try await AgenticConversationSession(
            workspace: FileManager.default.temporaryDirectory.path,
            service: host,
            capabilities: try await host.capabilities(),
            sessionID: "compact-conversation"
        )
        await conversation.runContextCommand("compact")
        guard case .command(let card)? = await conversation.snapshot.messages.last?.attachments.first else {
            try Expect.true(false, ":compact leaves a card")
            return []
        }
        try Expect.true(card.outcome.hasPrefix("nothing to compact"), "nothing old enough: \(card.outcome)")
        try Expect.true(card.trace.contains { $0.contains(":compact → nothing to compact") }, "traced: \(card.trace)")
        try Expect.equal(
            AgenticConsoleCommands.catalog.definition(for: "compact")?.contextEffect,
            .history,
            ":compact says it changes the history later requests carry"
        )
        return [.field("summary", change.summary)]
    }
}
