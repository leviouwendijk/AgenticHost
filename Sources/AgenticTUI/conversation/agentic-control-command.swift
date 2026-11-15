import AgenticInterfaces
import AgenticRuntime
import Foundation

/// Run control, typed without `:`.
///
///     interrupt [next|force]      force (default, also ctrl-g): stop at the
///                                 earliest safe boundary; next: finish the
///                                 current iteration, then stop
///     queue [force|next|await]    what a message sent during a run does;
///                                 none: show the current policy
package enum AgenticControlCommand: Sendable, Hashable {
    case interrupt(Run.Interruption.Mode)
    case queue(AgenticQueuePolicy?)

    package static let names: Set<String> = ["interrupt", "queue"]

    package static let usage = "usage: :interrupt [next|force] · :queue [force|next|await]"

    package init(
        parsing text: String
    ) throws {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let name = words.first, words.count <= 2 else { throw Failure.usage }
        let argument = words.dropFirst().first
        switch name {
        case "interrupt":
            switch argument {
            case nil, "force": self = .interrupt(.urgent)
            case "next": self = .interrupt(.graceful)
            default: throw Failure.usage
            }
        case "queue":
            guard let argument else {
                self = .queue(nil)
                return
            }
            guard let policy = AgenticQueuePolicy(rawValue: argument) else { throw Failure.usage }
            self = .queue(policy)
        default:
            throw Failure.usage
        }
    }

    package static func isControlCommand(_ text: String) -> Bool {
        names.contains(text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? text)
    }

    package enum Failure: Error, LocalizedError {
        case usage

        package var errorDescription: String? {
            AgenticControlCommand.usage
        }
    }
}
