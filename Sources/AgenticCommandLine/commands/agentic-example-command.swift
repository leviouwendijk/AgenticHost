import AgenticRuntime
import Arguments
import Foundation

public struct AgenticExampleOptions: Sendable, ArgumentParsed {
    public typealias ArgumentPayload = Payload

    /// nil lists the examples.
    public let target: String?

    public init(arguments: Payload) throws {
        self.target = arguments.target.isEmpty ? nil : arguments.target
    }

    public struct Payload: ArgumentGroup {
        @Arg(
            "target",
            help: "Which file: settings, or a domain such as scheduling; lists them when omitted.",
            default: ""
        )
        public var target: String

        public init() {}
    }
}

/// Prints a `.frame` file to start from, from the same source the program
/// reads and tests:
///
///     agentic example                      what there is, and where it goes
///     agentic example scheduling > ~/.agentic/domains/scheduling.frame
public enum AgenticExampleCommand<Application: AgenticApplicationProviding>: ParsedArgumentCommand {
    public typealias Options = AgenticExampleOptions
    public static var name: String { "example" }

    public static func run(_ options: Options, invocation: ParsedInvocation) async throws {
        _ = invocation
        let examples = AgenticFrameExample.all(for: Application.self)

        guard let target = options.target else {
            let home = AgentHomeLocator().resolveHome().root
            let width = examples.map(\.name.count).max() ?? 0
            for example in examples {
                let name = example.name.padding(toLength: width, withPad: " ", startingAt: 0)
                print("\(name)  \(home.appendingPathComponent(example.path).path)")
                print("\(String(repeating: " ", count: width))  \(example.summary)")
            }
            return
        }
        guard let example = examples.first(where: { $0.name == target }) else {
            throw AgenticExampleCommandError.unknown(target, known: examples.map(\.name))
        }
        print(example.text, terminator: example.text.hasSuffix("\n") ? "" : "\n")
    }
}

public enum AgenticExampleCommandError: Error, LocalizedError {
    case unknown(String, known: [String])

    public var errorDescription: String? {
        switch self {
        case .unknown(let target, let known):
            return "no example '\(target)'; there is: \(known.joined(separator: ", "))"
        }
    }
}
