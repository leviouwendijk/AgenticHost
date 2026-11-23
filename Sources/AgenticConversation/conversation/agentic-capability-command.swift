import Agentic
import AgenticPresentation
import Foundation
import Primitives

/// Installed capabilities invoked from the command bar, typed without `:`.
///
///     program <identifier> <json>     the same invocation as `/program`
///     inference <identifier> <json>   an Inference's typed output
public enum AgenticCapabilityCommand: Sendable {
    case program(AgenticConversationProgramInvocation)
    case inference(InferenceIdentifier, JSONValue)

    package static let definitions: [AgenticCommandDefinition] = [
        .init(
            name: "program",
            syntax: ["program <identifier> <json>"],
            summary: "Run an installed Program, as /program does.",
            chapter: .capabilities,
            surfaces: [.conversation],
            isTraced: true,
            contextEffect: .transcript
        ),
        .init(
            name: "inference",
            syntax: ["inference <identifier> <json>"],
            summary: "An installed Inference's typed output, outside the model's transcript.",
            chapter: .capabilities,
            surfaces: [.conversation],
            isTraced: true
        ),
    ]

    package static let names = Set(definitions.map(\.name))

    public init(
        parsing text: String
    ) throws {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let name = parts.first.map(String.init) else { throw Failure.usage }
        let rest = parts.count > 1 ? String(parts[1]) : ""
        switch name {
        case "program":
            // One parser, one semantic invocation, whichever entry point.
            guard let invocation = try AgenticConversationProgramCommand.parse("/program " + rest) else {
                throw Failure.usage
            }
            self = .program(invocation)
        case "inference":
            let pieces = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let identifier = pieces.first.map(String.init), pieces.count == 2 else {
                throw Failure.usage
            }
            guard let input = try? JSONDecoder().decode(JSONValue.self, from: Data(pieces[1].utf8)) else {
                throw Failure.invalidInput(identifier)
            }
            self = .inference(InferenceIdentifier(rawValue: identifier), input)
        default:
            throw Failure.usage
        }
    }

    /// Completes the identifier after `program ` or `inference `.
    public static func completer(
        programs: [String],
        inferences: [String]
    ) -> AgenticCommandCompleter {
        { text in
            let words = text.split(separator: " ", omittingEmptySubsequences: false)
            guard words.count == 2 else { return nil }
            let candidates: [String]
            switch words[0] {
            case "program": candidates = programs
            case "inference": candidates = inferences
            default: return nil
            }
            let partial = String(words[1])
            let matches = candidates.filter { $0.hasPrefix(partial) }.sorted()
            guard !matches.isEmpty else { return nil }
            return .init(
                replacing: partial.count,
                candidates: matches.map { .init(text: $0 + " ", title: $0) }
            )
        }
    }

    package enum Failure: Error, LocalizedError {
        case usage
        case invalidInput(String)

        package var errorDescription: String? {
            switch self {
            case .usage:
                return AgenticCommandCatalog(AgenticCapabilityCommand.definitions).usage(["program", "inference"])
            case .invalidInput(let identifier):
                return "Inference '\(identifier)' input is not valid JSON."
            }
        }
    }
}
