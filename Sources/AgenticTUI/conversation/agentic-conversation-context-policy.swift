import Agentic

extension Context.Policy {
    /// Context budget of an interactive conversation. Four recent user turns
    /// stay at full fidelity; older bulky results are elided to stubs that
    /// point into the session log, and only a conversation exceeding its
    /// history budget loses whole turns.
    static let conversation = Context.Policy(
        preferredInputTokens: 16_000,
        maximumInputTokens: 96_000,
        reservedOutputTokens: 8_000,
        history: .init(
            maximumTurns: 4,
            maximumTokens: 32_000,
            elideResultsOver: 512
        )
    )
}
