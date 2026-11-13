import Agentic
import AgenticRuntime
import Arguments
import Foundation
import Primitives

public struct AgenticLogOptions: Sendable, ArgumentParsed {
    public typealias ArgumentPayload = Payload

    /// nil lists the sessions that have a log.
    public let session: String?
    public let step: Int?
    public let kinds: Set<Run.Log.Entry.Kind>?

    public init(arguments: Payload) throws {
        self.session = arguments.session.isEmpty ? nil : arguments.session
        self.step = try arguments.step.map { raw in
            guard let step = Int(raw) else {
                throw AgenticLogCommandError.invalidStep(raw)
            }
            return step
        }
        self.kinds = try arguments.kind.map { raw in
            try Set(raw.split(separator: ",").map { name in
                guard let kind = Run.Log.Entry.Kind(rawValue: String(name)) else {
                    throw AgenticLogCommandError.unknownKind(String(name))
                }
                return kind
            })
        }
    }

    public struct Payload: ArgumentGroup {
        @Arg(
            "session",
            help: "Session to read; lists sessions when omitted.",
            default: ""
        )
        public var session: String

        @Opt(
            "step",
            help: "Print one step in full, by sequence number."
        )
        public var step: String?

        @Opt(
            "kind",
            help: "Only these kinds, comma separated: state, observation, request, message, call, response, branch."
        )
        public var kind: String?

        public init() {}
    }
}

/// Reads the durable session logs in the Agentic home.
public enum AgenticLogCommand<Application: AgenticApplicationProviding>: ParsedArgumentCommand {
    public typealias Options = AgenticLogOptions
    public static var name: String { "log" }

    public static func run(_ options: Options, invocation: ParsedInvocation) async throws {
        _ = invocation
        let store = try Run.Log.Store.home(AgentHomeLocator().resolveHome())

        guard let session = options.session else {
            for session in try store.sessions() {
                print(session)
            }
            return
        }

        let contents = try store.read(session: session)

        if let step = options.step {
            guard let entry = contents.entries.first(where: { $0.seq == step }) else {
                throw AgenticLogCommandError.stepNotFound(step)
            }
            print(line(entry))
            print(try store.detail(of: entry, session: session).toJSONString())
            return
        }

        for entry in contents.entries
        where options.kinds.map({ $0.contains(entry.kind) }) ?? true {
            print(line(entry))
        }
    }

    private static func line(_ entry: Run.Log.Entry) -> String {
        let time = entry.time.formatted(date: .omitted, time: .standard)
        return "\(entry.seq)\t\(time)\t\(entry.run ?? "-")\t\(entry.kind.rawValue)\t\(entry.summary)"
    }
}

public enum AgenticLogCommandError: Error, Sendable, Equatable, LocalizedError {
    case invalidStep(String)
    case unknownKind(String)
    case stepNotFound(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidStep(let raw): "Not a step number: \(raw)."
        case .unknownKind(let raw): "Unknown entry kind: \(raw)."
        case .stepNotFound(let step): "No step \(step) in this log."
        }
    }
}
