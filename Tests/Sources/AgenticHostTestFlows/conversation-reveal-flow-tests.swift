import Agentic
import AgenticInterfaces
import AgenticSensitivity
@_spi(Testing) import AgenticTUI
import DSL
import Foundation
import Sensitivity
import TestFlows

extension AgentHostLocalFlowTesting {
    /// Handles reach the owner's screen as marked values; the session's own
    /// snapshot, like the model and the records, keeps handles.
    static func runConversationReveal() async throws -> [TestDiagnostic] {
        let vault = Sensitivity.Vault(lifetime: .seconds(60))
        let sam = await vault.handle(for: "sam@example.com", kind: .contact, tier: .handle, detector: "email", reason: "address", score: 90, source: "mail_read")
        let key = await vault.handle(for: "sk-test-1234567890abcdef", kind: .secret, tier: .handle, detector: "token", reason: "key", score: 95, source: "read_file")
        let entries = await vault.displayEntries()

        var stored = AgenticConversationSnapshot(
            workspace: "~",
            messages: [.init(id: "m1", role: .assistant, body: "Block \(sam.token)? Key \(key.token).")],
            models: [],
            preferredModelProfileID: AgentModelProfileIdentifier(rawValue: "test")
        )
        stored.hostConsole.documents = [
            .init(
                id: "d1", runID: "r1", stepID: "s1", kind: .details,
                body: "from \(sam.token)",
                structuredBody: .paragraph([.text("to \(sam.token)")]),
                previewPrelude: "Apply to \(sam.token)"
            ),
        ]

        let shown = stored.revealing(Privacy.Reveal(mode: .revealed, entries: entries))
        try Expect.equal(shown.messages[0].body, "Block ⟨sam@example.com ✉⟩? Key ⟨\(entries.first { $0.description.handle == key }!.description.preview) ⚿⟩.", "values marked; a secret masked")
        try Expect.equal(shown.hostConsole.documents[0].body, "from ⟨sam@example.com ✉⟩", "documents")
        try Expect.equal(shown.hostConsole.documents[0].previewPrelude, "Apply to ⟨sam@example.com ✉⟩", "approval previews")
        try Expect.equal(shown.hostConsole.documents[0].structuredBody, .paragraph([.text("to ⟨sam@example.com ✉⟩")]), "structured content, through its encoded form")
        try Expect.equal(stored.messages[0].body, "Block \(sam.token)? Key \(key.token).", "the stored snapshot keeps handles")

        let masked = stored.revealing(Privacy.Reveal(mode: .masked, entries: entries))
        try Expect.false(masked.messages[0].body.contains("sam@example.com"), "masked shows previews only")
        try Expect.equal(stored.revealing(.handles), stored, "handles mode changes nothing")
        return []
    }
}
