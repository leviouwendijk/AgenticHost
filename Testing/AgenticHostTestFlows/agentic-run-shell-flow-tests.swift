import AgenticCommandLine

/// Verifies shell command parsing independently of terminal presentation.
enum AgenticRunShellFlowTesting {
    enum Failure: Error {
        case unexpectedCommand(String)
        case acceptedMalformedCommand
    }

    static func run() throws {
        try expect("agents", .agents)
        try expect("session start main_orchestrator", .start(agent: "main_orchestrator"))
        try expect("session use abc", .use(session: "abc"))
        try expect("send inspect the source; do not mutate", .send(prompt: "inspect the source; do not mutate"))
        try expect("workers", .workers)
        try expect("worker interrupt child:42 urgent", .interruptWorker(id: "child:42", mode: .urgent))
        try expect("worker continue child:42", .continueWorker(id: "child:42"))
        try expect("interaction approve request-4", .interactionApproval(.approved, requestID: "request-4"))
        try expect("interaction continue request-4 25", .interactionContinue(requestID: "request-4", iterations: 25))
        try expect("interaction stop request-4", .interactionStop(requestID: "request-4"))
        try expect("quit", .quit(force: false))
        try expect("\\q", .quit(force: false))
        guard (try? AgenticRunShellParser.parse("interaction approve")) == nil,
              (try? AgenticRunShellParser.parse("interaction continue request-4 -1")) == nil,
              (try? AgenticRunShellParser.parse("session start")) == nil else {
            throw Failure.acceptedMalformedCommand
        }
    }

    private static func expect(
        _ source: String,
        _ expected: AgenticRunShellInstruction
    ) throws {
        guard try AgenticRunShellParser.parse(source) == expected else {
            throw Failure.unexpectedCommand(source)
        }
    }
}
