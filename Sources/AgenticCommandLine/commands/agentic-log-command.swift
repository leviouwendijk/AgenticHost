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
            help: "Session ID, unique ID prefix, or 'latest'; lists sessions when omitted.",
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

        guard let reference = options.session else {
            print(table(try store.summaries()))
            return
        }
        let session = try store.resolve(reference)

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

    /// Most recent first: when, where, which agent, how long, what was asked.
    private static func table(_ summaries: [Run.Log.Summary]) -> String {
        let date = Date.FormatStyle().month(.twoDigits).day(.twoDigits).hour().minute()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let rows = summaries.map { summary -> [String] in
            let workspace = summary.header.metadata["workspace"].map {
                $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0
            } ?? "-"
            let prompt = (summary.firstPrompt ?? "")
                .split(whereSeparator: \.isNewline).joined(separator: " ")
            return [
                String(summary.session.prefix(8)),
                summary.header.created.formatted(date),
                summary.lastActivity.formatted(date),
                String(summary.steps),
                summary.header.metadata["agent"] ?? "-",
                workspace,
                prompt.count > 48 ? String(prompt.prefix(47)) + "…" : prompt,
            ]
        }
        let header = ["ID", "STARTED", "LAST", "STEPS", "AGENT", "WORKSPACE", "FIRST PROMPT"]
        let all = [header] + rows
        let widths = header.indices.map { column in
            all.map { $0[column].count }.max() ?? 0
        }
        return all.map { row in
            row.indices.map { column in
                column == row.count - 1
                    ? row[column]
                    : row[column].padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
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
