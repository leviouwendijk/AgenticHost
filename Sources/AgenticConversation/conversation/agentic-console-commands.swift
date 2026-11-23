import AgenticPresentation

/// Every `:` command the work console installs. Dispatch, the composer's
/// command set, usage text and help read this one catalog.
public enum AgenticConsoleCommands {
    public static let catalog = AgenticCommandCatalog(
        AgenticWorkspaceCommand.definitions
            + AgenticControlCommand.definitions
            + AgenticCapabilityCommand.definitions
            + staged
            + context
            + AgenticExportCommand.definitions
    )

    /// `:context`: the changes the conversation has shown.
    package static let context: [AgenticCommandDefinition] = [
        .init(
            name: "context",
            syntax: ["context [all]"],
            summary: "The changes to the latest run's context, routes and capabilities; all: the whole conversation's.",
            chapter: .context,
            surfaces: [.conversation]
        ),
        .init(
            name: "compact",
            syntax: ["compact"],
            summary: "Replace older tool results with pointers to their preserved copies: one cache miss, then a stable prefix. The two newest turns stay whole.",
            chapter: .context,
            surfaces: [.conversation],
            isTraced: true,
            contextEffect: .history
        ),
        .init(
            name: "declare",
            syntax: ["declare"],
            summary: "Declare the selected capabilities to the provider at the next turn, applying pending changes: one cache miss. Otherwise they apply when the cache is lost anyway (compaction, expiry, a model switch).",
            chapter: .context,
            surfaces: [.conversation],
            isTraced: true
        ),
        .init(
            name: "reveal",
            syntax: ["reveal [on|masked|off|default]"],
            summary: "How this screen shows scrubbed values (⟦kind:id⟧ handles): on shows the values, marked ⟨value ✉⟩; masked shows previews; off shows handles; default follows sensitivity.frame. The model and the records always keep handles.",
            chapter: .context,
            surfaces: [.conversation]
        ),
        .init(
            name: "retro",
            syntax: ["retro"],
            summary: "Review this conversation's log in a separate session and record verified harness findings in improvements/; the conversation itself is unchanged.",
            chapter: .context,
            surfaces: [.conversation],
            isTraced: true
        ),
    ]

    /// `:review`, `:publish`, `:discard`: a conversation's staged changes.
    package static let staged: [AgenticCommandDefinition] = [
        .init(
            name: "review",
            syntax: ["review"],
            summary: "Open the staged changes' review.",
            chapter: .review
        ),
        .init(
            name: "publish",
            syntax: ["publish"],
            summary: "Publish every staged change.",
            chapter: .review,
            isTraced: true
        ),
        .init(
            name: "discard",
            syntax: ["discard"],
            summary: "Discard every staged change.",
            chapter: .review,
            isTraced: true
        ),
    ]
}

extension AgenticCommandCatalog {
    /// `usage: :a · :b` for the commands named.
    func usage(
        _ names: [String]
    ) -> String {
        "usage: " + definitions
            .filter { names.contains($0.name) }
            .flatMap(\.syntax)
            .map { ":" + $0 }
            .joined(separator: " · ")
    }
}
