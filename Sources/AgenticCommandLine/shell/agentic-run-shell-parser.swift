import Agentic
import AgenticRuntime
import Foundation

/// Prompts and text replies consume the remainder of their command line.
public enum AgenticRunShellFeedback: String, Sendable {
    case quiet
    case normal
    case verbose
}

public enum AgenticRunShellInstruction: Sendable, Equatable {
    case help
    case agents
    case sessions
    case start(agent: String)
    case use(session: String)
    case detach
    case send(prompt: String)
    case feedback(AgenticRunShellFeedback)
    case status
    case workers
    case interrupt(mode: Run.Interruption.Mode)
    case interruptWorker(id: String, mode: Run.Interruption.Mode)
    case continueWorker(id: String)
    case mutations
    case interactionShow
    case interactionRespond(requestID: String, text: String)
    case interactionApproval(ApprovalDecision, requestID: String)
    case interactionContinue(requestID: String, iterations: Int)
    case interactionStop(requestID: String)
    case quit(force: Bool)
}

public enum AgenticRunShellParseError: Error, LocalizedError, Sendable {
    case usage(String)

    public var errorDescription: String? {
        switch self {
        case .usage(let message): return message
        }
    }
}

public enum AgenticRunShellParser {
    public static func parse(_ source: String) throws -> AgenticRunShellInstruction? {
        let line = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let (verb, rest) = split(line)
        switch verb {
        case "help", "\\?":
            guard rest.isEmpty else { throw AgenticRunShellParseError.usage("Usage: help") }
            return .help
        case "agents":
            guard rest.isEmpty else { throw AgenticRunShellParseError.usage("Usage: agents") }
            return .agents
        case "ls":
            switch rest {
            case "agents": return .agents
            case "sessions": return .sessions
            case "workers": return .workers
            default: throw AgenticRunShellParseError.usage("Usage: ls agents|sessions|workers")
            }
        case "sessions":
            guard rest.isEmpty else { throw AgenticRunShellParseError.usage("Usage: sessions") }
            return .sessions
        case "session":
            let (action, argument) = split(rest)
            switch action {
            case "start":
                guard oneWord(argument) else { throw AgenticRunShellParseError.usage("Usage: session start <agent-id>") }
                return .start(agent: argument)
            case "use":
                guard oneWord(argument) else { throw AgenticRunShellParseError.usage("Usage: session use <session-id>") }
                return .use(session: argument)
            case "detach":
                guard argument.isEmpty else { throw AgenticRunShellParseError.usage("Usage: session detach") }
                return .detach
            default:
                throw AgenticRunShellParseError.usage("Usage: session start <agent-id> | session use <session-id> | session detach")
            }
        case "send":
            guard !rest.isEmpty else { throw AgenticRunShellParseError.usage("Usage: send <prompt>") }
            return .send(prompt: rest)
        case "feedback":
            guard oneWord(rest), let mode = AgenticRunShellFeedback(rawValue: rest) else {
                throw AgenticRunShellParseError.usage("Usage: feedback quiet|normal|verbose")
            }
            return .feedback(mode)
        case "status":
            guard rest.isEmpty else { throw AgenticRunShellParseError.usage("Usage: status") }
            return .status
        case "workers":
            guard rest.isEmpty else { throw AgenticRunShellParseError.usage("Usage: workers") }
            return .workers
        case "worker":
            let (action, argument) = split(rest)
            switch action {
            case "interrupt":
                let (id, mode) = split(argument)
                guard oneWord(id) else { throw AgenticRunShellParseError.usage("Usage: worker interrupt <worker-id> [graceful|urgent]") }
                return .interruptWorker(id: id, mode: try interruptionMode(mode, default: .graceful))
            case "continue":
                guard oneWord(argument) else { throw AgenticRunShellParseError.usage("Usage: worker continue <worker-id>") }
                return .continueWorker(id: argument)
            default:
                throw AgenticRunShellParseError.usage("Usage: worker interrupt <worker-id> [mode] | worker continue <worker-id>")
            }
        case "interrupt":
            return .interrupt(mode: try interruptionMode(rest, default: .graceful))
        case "interaction":
            let (action, value) = split(rest)
            switch action {
            case "show":
                guard value.isEmpty else {
                    throw AgenticRunShellParseError.usage("Usage: interaction show")
                }
                return .interactionShow
            case "respond":
                let (requestID, text) = split(value)
                guard oneWord(requestID), !text.isEmpty else {
                    throw AgenticRunShellParseError.usage("Usage: interaction respond <interaction-id> <answer text>")
                }
                return .interactionRespond(requestID: requestID, text: text)
            case "approve", "deny", "skip":
                guard oneWord(value) else {
                    throw AgenticRunShellParseError.usage("Usage: interaction approve|deny|skip <interaction-id>")
                }
                let decision: ApprovalDecision = action == "approve" ? .approved : (action == "deny" ? .denied : .skipped)
                return .interactionApproval(decision, requestID: value)
            case "continue":
                let (requestID, total) = split(value)
                guard oneWord(requestID), oneWord(total), let iterations = Int(total), iterations > 0 else {
                    throw AgenticRunShellParseError.usage("Usage: interaction continue <interaction-id> <total-iteration-limit>")
                }
                return .interactionContinue(requestID: requestID, iterations: iterations)
            case "stop":
                guard oneWord(value) else { throw AgenticRunShellParseError.usage("Usage: interaction stop <interaction-id>") }
                return .interactionStop(requestID: value)
            default:
                throw AgenticRunShellParseError.usage("Usage: interaction show | respond <id> <text> | approve|deny|skip <id> | continue <id> <total-limit> | stop <id>")
            }
        case "mutations":
            guard rest.isEmpty else { throw AgenticRunShellParseError.usage("Usage: mutations") }
            return .mutations
        case "quit", "exit", "\\q":
            guard rest.isEmpty || rest == "--force" else { throw AgenticRunShellParseError.usage("Usage: quit [--force]") }
            return .quit(force: rest == "--force")
        default:
            throw AgenticRunShellParseError.usage("Unknown command '\(verb)'. Type help for available commands.")
        }
    }

    private static func split(_ string: String) -> (String, String) {
        let parts = string.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard let first = parts.first else { return ("", "") }
        return (String(first), parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : "")
    }

    private static func oneWord(_ string: String) -> Bool {
        !string.isEmpty && !string.contains(where: \.isWhitespace)
    }

    private static func interruptionMode(
        _ value: String,
        default defaultMode: Run.Interruption.Mode
    ) throws -> Run.Interruption.Mode {
        switch value {
        case "": return defaultMode
        case "graceful": return .graceful
        case "urgent": return .urgent
        default: throw AgenticRunShellParseError.usage("Interruption mode must be graceful or urgent.")
        }
    }
}
