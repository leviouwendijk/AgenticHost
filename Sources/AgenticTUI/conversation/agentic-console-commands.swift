import AgenticInterfaces

/// Every `:` command the work console installs. Dispatch, the composer's
/// command set, usage text and help read this one catalog.
package enum AgenticConsoleCommands {
    package static let catalog = AgenticCommandCatalog(
        AgenticWorkspaceCommand.definitions
            + AgenticControlCommand.definitions
            + AgenticCapabilityCommand.definitions
            + staged
            + context
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
