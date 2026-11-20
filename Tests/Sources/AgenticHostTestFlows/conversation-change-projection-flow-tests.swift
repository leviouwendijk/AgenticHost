import Agentic
import AgenticSessions
import AgenticContextWindow
import AgenticRuntime
import AgenticInterfaces
import AgenticHost
import Foundation
import TestFlows
import AgenticTUI

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
        // An answer names the model that gave it; a reroute is a change.
        let models = [AgenticConversationModelPresentation(id: "selected.sonnet", title: "Sonnet 5.5", detail: "")]
        let plain = Run.Event.Route(
            profileID: "served.opus", title: "Opus 5.5", gateway: "anthropic_messages", model: "claude-opus-5-5",
            tier: .frontier, preferredProfileID: nil, isRerouted: false, reason: nil
        )
        try Expect.equal(
            AgenticConversationChangeProjection.route(plain, models: models),
            .init(title: "Opus 5.5", provider: "anthropic_messages"),
            "a plain route names model and provider"
        )
        let rerouted = Run.Event.Route(
            profileID: "served.qwen", title: "Qwen 3.5", gateway: "ollama", model: "qwen",
            tier: .light, preferredProfileID: "selected.sonnet", isRerouted: true, reason: "Preferred profile is unavailable."
        )
        try Expect.equal(
            AgenticConversationChangeProjection.route(rerouted, models: models).selectedTitle,
            "Sonnet 5.5",
            "a reroute names the selected model by its title"
        )
        let card = AgenticConversationChangeProjection.reroute(
            Run.Event.State(kind: .model_routed, iteration: 0, summary: "", route: rerouted),
            route: rerouted, runID: "run-1", models: models
        )
        try Expect.true(
            card.kind == .route && card.summary == "Sonnet 5.5 → Qwen 3.5" && card.reason == "Preferred profile is unavailable.",
            "the reroute is a route change with its reason: \(card.line)"
        )

        // A run's opening: what the first request carried, by source and cost.
        let opened = Run.Event.State(
            kind: .capability_changed, iteration: 0, summary: "",
            capabilityChanges: [
                .init(reference: .tool("read_files"), operation: .exposed, source: .declared),
                .init(reference: .tool("list_capabilities"), operation: .exposed, source: .discovery),
            ]
        )
        let advertised = Run.Event.State(
            kind: .schemas_advertised, iteration: 0, summary: "",
            advertisement: .init(
                detail: .core, reason: .core,
                entries: [
                    .init(name: "read_files", reference: .tool("read_files"), detail: .core, estimatedTokens: 300, fullTokens: 900),
                    .init(name: "list_capabilities", reference: .tool("list_capabilities"), detail: .full, estimatedTokens: 120, fullTokens: 120),
                ],
                rewritesCachedPrefix: false
            )
        )
        let opening = try Expect.notNil(
            AgenticConversationChangeProjection.opening(advertised, events: [opened, advertised], runID: "run-1"),
            "the first advertisement is an opening card"
        )
        try Expect.equal(opening.summary, "opened with 2 tools · ≈420 tokens", "the opening counts tools and tokens")
        try Expect.equal(
            opening.reason, "declared 1 · discovery 1; 1 in core form, ≈1020 in full",
            "and says what put them in view"
        )
        try Expect.equal(
            opening.items.map(\.detail),
            ["≈300 core (≈900 full) · declared", "≈120 · discovery"],
            "each tool with its cost and source"
        )

        // The host's logs are the owner's session catalog by default; a
        // host-supplied catalog is kept; workers have it withheld.
        let logs = Run.Log.Store(storage: .init(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
        ))
        let defaulted = try agentHostLocalSessionCatalog(logs, in: ToolServices())
        try Expect.true(
            (try? defaulted.require((any Sessions.CatalogReading).self)) is Run.Log.Store,
            "the logs serve as the catalog"
        )
        try Expect.true(
            (try? agentHostLocalSessionCatalog(nil, in: ToolServices()).require((any Sessions.CatalogReading).self)) == nil,
            "no logs, no catalog: nothing pretends to be one"
        )
        try Expect.true(
            (try? defaulted.removing((any Sessions.CatalogReading).self).require((any Sessions.CatalogReading).self)) == nil,
            "a worker's scope drops it"
        )

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
