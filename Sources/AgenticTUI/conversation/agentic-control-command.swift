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
///     queue clear                 cancel every held message; its text goes
///                                 back to the message box
package enum AgenticControlCommand: Sendable, Hashable {
    case interrupt(Run.Interruption.Mode)
    case queue(AgenticQueuePolicy?)
    case queueClear

    package static let definitions: [AgenticCommandDefinition] = [
        .init(
            name: "interrupt",
            syntax: ["interrupt [next|force]"],
            summary: "Stop the run: force (ctrl-g) at the earliest safe boundary, next after the current iteration.",
            chapter: .run,
            isTraced: true
        ),
        .init(
            name: "queue",
            syntax: ["queue [force|next|await]", "queue clear"],
            summary: "What a message sent during a run does; none: show the policy; clear: cancel held messages.",
            chapter: .run
        ),
    ]

    package static let names = Set(definitions.map(\.name))

    package static let usage = AgenticCommandCatalog(definitions).usage(["interrupt", "queue"])

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
            if argument == "clear" {
                self = .queueClear
                return
            }
            guard let policy = AgenticQueuePolicy(rawValue: argument) else { throw Failure.usage }
            self = .queue(policy)
        default:
            throw Failure.usage
        }
    }

    package enum Failure: Error, LocalizedError {
        case usage

        package var errorDescription: String? {
            AgenticControlCommand.usage
        }
    }
}
