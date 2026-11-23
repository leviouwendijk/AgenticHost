import Agentic

extension ContextWindow.Policy {
    /// Context budget of an interactive conversation. History is
    /// append-only: nothing sent is rewritten, so the provider's prompt
    /// cache keeps hitting. Past 60% of the input limit the conversation is
    /// advised to `:compact`; a request that would not fit pauses before it
    /// is sent. Compaction replaces older results with pointers that the
    /// session readers resolve. Schemas are advertised in core form when the
    /// Agent can inspect capabilities for the rest.
    static let conversation = ContextWindow.Policy(
        preferredInputTokens: 16_000,
        maximumInputTokens: 96_000,
        reservedOutputTokens: 8_000,
        history: .init(
            maximumTurns: 4,
            maximumTokens: 32_000,
            elideResultsOver: 512,
            elisionBatch: 4,
            mode: .append_only,
            softLimit: 0.6
        ),
        schemas: .core
    )
}
