import Agentic
import AgenticConfiguration
import AgenticHost
import AgenticIntents
import AgenticRuntime
import Arguments
import Foundation

/// Tool calls unattended runs deferred for review: list them, read one,
/// decide on it, and run an approved one.
public enum AgenticIntentsCommand<
    Application: AgenticApplicationProviding
>:
    ArgumentCommand
{
    public static var name: String {
        "intents"
    }

    public static var defaultChild: Help.Type {
        Help.self
    }

    public static var children: [ArgumentCommandType] {
        [
            Help.self,
            List.self,
            Read.self,
            Review.self,
            Execute.self,
        ]
    }

    static func manager() -> Intents.Manager {
        .home(AgentHomeLocator().resolveHome())
    }

    /// An exact id, or a prefix that matches exactly one intent.
    static func resolve(
        _ reference: String,
        in manager: Intents.Manager
    ) async throws -> Intents.Intent.ID {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = try await manager.list(includeExpired: true)
            .map(\.id)
            .filter { $0.raw == reference || $0.raw.hasPrefix(reference) }
        if let exact = matches.first(where: { $0.raw == reference }) {
            return exact
        }
        guard matches.count == 1, let id = matches.first else {
            throw matches.isEmpty
                ? AgenticIntentsCommandError.notFound(reference)
                : AgenticIntentsCommandError.ambiguous(reference, matches.map(\.raw))
        }
        return id
    }

    static func write(
        _ intent: Intents.Intent
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(intent), as: UTF8.self))
    }

    public enum Help:
        RunnableArgumentCommand
    {
        public static var name: String {
            "help"
        }

        public static func run(
            _ invocation: ParsedInvocation
        ) async throws {
            _ = invocation
            print(
                ArgumentHelpRenderer().render(
                    command: try AgenticIntentsCommand<Application>.spec()
                )
            )
        }
    }

    public enum List:
        ParsedArgumentCommand
    {
        public typealias Options = AgenticIntentsListOptions

        public static var name: String {
            "list"
        }

        public static func run(
            _ options: Options,
            invocation: ParsedInvocation
        ) async throws {
            _ = invocation
            let intents = try await AgenticIntentsCommand<Application>.manager().list(
                statuses: options.statuses,
                sessionID: options.sessionID,
                tool: options.tool.map(ToolIdentifier.init(rawValue:)),
                includeExpired: options.includeExpired
            )
            print(AgenticIntentsTable.render(intents))
        }
    }

    public enum Read:
        ParsedArgumentCommand
    {
        public typealias Options = AgenticIntentsReferenceOptions

        public static var name: String {
            "read"
        }

        public static func run(
            _ options: Options,
            invocation: ParsedInvocation
        ) async throws {
            _ = invocation
            let manager = AgenticIntentsCommand<Application>.manager()
            let id = try await AgenticIntentsCommand<Application>.resolve(options.reference, in: manager)
            try AgenticIntentsCommand<Application>.write(try await manager.intent(id))
        }
    }

    public enum Review:
        ParsedArgumentCommand
    {
        public typealias Options = AgenticIntentsReviewOptions

        public static var name: String {
            "review"
        }

        public static func run(
            _ options: Options,
            invocation: ParsedInvocation
        ) async throws {
            _ = invocation
            let manager = AgenticIntentsCommand<Application>.manager()
            let id = try await AgenticIntentsCommand<Application>.resolve(options.reference, in: manager)
            let intent = try await manager.review(
                id,
                decision: options.decision,
                reviewer: options.reviewer,
                note: options.note
            )
            print("\(intent.id): \(intent.status.rawValue)")
        }
    }

    public enum Execute:
        ParsedArgumentCommand
    {
        public typealias Options = AgenticIntentsExecuteOptions

        public static var name: String {
            "execute"
        }

        public static func run(
            _ options: Options,
            invocation: ParsedInvocation
        ) async throws {
            _ = invocation
            let manager = AgenticIntentsCommand<Application>.manager()
            let id = try await AgenticIntentsCommand<Application>.resolve(options.reference, in: manager)
            let sessionID = try await manager.intent(id).sessionID
            let services = try AgenticSessionServices.resolve(
                Application.self,
                sessionID: sessionID
            )
            let host = try await AgenticRuntime.resolve(Application.self).host(
                workspace: options.workspace,
                sessionID: sessionID,
                services: services
            )
            let intent = try await Intents.Executor(
                manager: manager,
                tools: host.tools
            ).execute(
                id,
                in: ToolContext(
                    workspace: host.workspace,
                    services: services
                )
            )
            try AgenticIntentsCommand<Application>.write(intent)
            if intent.status == .failed {
                throw AgenticIntentsCommandError.executionFailed(intent.id.raw)
            }
        }
    }
}

public struct AgenticIntentsListOptions:
    Sendable,
    ArgumentParsed
{
    public typealias ArgumentPayload = Payload

    public let statuses: [Intents.Intent.Status]
    public let sessionID: String?
    public let tool: String?
    public let includeExpired: Bool

    public init(
        arguments: Payload
    ) throws {
        self.statuses = try (arguments.status ?? "")
            .split(separator: ",")
            .map { raw in
                let name = raw.trimmingCharacters(in: .whitespaces)
                guard let status = Intents.Intent.Status(rawValue: name) else {
                    throw AgenticIntentsCommandError.unknownStatus(name)
                }
                return status
            }
        self.sessionID = arguments.session.flatMap { $0.isEmpty ? nil : $0 }
        self.tool = arguments.tool.flatMap { $0.isEmpty ? nil : $0 }
        self.includeExpired = arguments.expired
    }

    public struct Payload:
        ArgumentGroup
    {
        @Opt(
            "status",
            help: "Only these statuses, comma separated: pending, approved, executing, denied, cancelled, expired, executed, failed."
        )
        public var status: String?

        @Opt(
            "session",
            help: "Only intents deferred by this session."
        )
        public var session: String?

        @Opt(
            "tool",
            help: "Only calls to this tool, e.g. io_tool_mutate."
        )
        public var tool: String?

        @Flag(
            "expired",
            help: "Include pending or approved intents past their expiry."
        )
        public var expired: Bool

        public init() {}
    }
}

public struct AgenticIntentsReferenceOptions:
    Sendable,
    ArgumentParsed
{
    public typealias ArgumentPayload = Payload

    public let reference: String

    public init(
        arguments: Payload
    ) throws {
        guard !arguments.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgenticIntentsCommandError.missingID
        }
        self.reference = arguments.id
    }

    public struct Payload:
        ArgumentGroup
    {
        @Arg(
            "id",
            help: "Intent id, or a prefix matching exactly one intent.",
            default: ""
        )
        public var id: String

        public init() {}
    }
}

public struct AgenticIntentsReviewOptions:
    Sendable,
    ArgumentParsed
{
    public typealias ArgumentPayload = Payload

    public let reference: String
    public let decision: Intents.Review.Decision
    public let note: String?
    public let reviewer: String?

    public init(
        arguments: Payload
    ) throws {
        guard !arguments.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgenticIntentsCommandError.missingID
        }
        guard let decision = Intents.Review.Decision(rawValue: arguments.decision) else {
            throw AgenticIntentsCommandError.unknownDecision(arguments.decision)
        }
        self.reference = arguments.id
        self.decision = decision
        self.note = arguments.note
        self.reviewer = arguments.reviewer ?? ProcessInfo.processInfo.userName
    }

    public struct Payload:
        ArgumentGroup
    {
        @Arg(
            "id",
            help: "Intent id, or a prefix matching exactly one intent.",
            default: ""
        )
        public var id: String

        @Arg(
            "decision",
            help: "approve, deny, cancel or expire. Approving does not run the intent.",
            default: ""
        )
        public var decision: String

        @Opt(
            "note",
            help: "Why; kept with the review."
        )
        public var note: String?

        @Opt(
            "reviewer",
            help: "Who decided; defaults to the current user."
        )
        public var reviewer: String?

        public init() {}
    }
}

public struct AgenticIntentsExecuteOptions:
    Sendable,
    ArgumentParsed
{
    public typealias ArgumentPayload = Payload

    public let reference: String
    public let workspace: AgenticRuntimeWorkspaceConfiguration

    public init(
        arguments: Payload
    ) throws {
        guard !arguments.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgenticIntentsCommandError.missingID
        }
        self.reference = arguments.id
        self.workspace = try arguments.workspace.configuration()
    }

    public struct Payload:
        ArgumentGroup
    {
        @Arg(
            "id",
            help: "Intent id, or a prefix matching exactly one intent. It must be approved.",
            default: ""
        )
        public var id: String

        /// The workspace the deferred call was prepared in.
        @Group("workspace")
        public var workspace: AgenticRuntimeWorkspaceArguments

        public init() {}
    }
}

enum AgenticIntentsTable {
    static func render(
        _ intents: [Intents.Intent]
    ) -> String {
        guard !intents.isEmpty else {
            return "No intents."
        }
        let date = Date.FormatStyle().month(.twoDigits).day(.twoDigits).hour().minute()
        let rows = intents.map { intent -> [String] in
            let summary = intent.preflight.summary
                .split(whereSeparator: \.isNewline).joined(separator: " ")
            return [
                String(intent.id.raw.prefix(8)),
                intent.status.rawValue,
                intent.updatedAt.formatted(date),
                intent.sessionID.map { String($0.prefix(8)) } ?? "-",
                intent.tool.rawValue,
                summary.count > 56 ? String(summary.prefix(55)) + "…" : summary,
            ]
        }
        let header = ["ID", "STATUS", "UPDATED", "SESSION", "TOOL", "CALL"]
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
}

public enum AgenticIntentsCommandError: Error, Sendable, Equatable, LocalizedError {
    case missingID
    case notFound(String)
    case ambiguous(String, [String])
    case unknownStatus(String)
    case unknownDecision(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingID:
            return "Give an intent id; `agentic intents list` shows them."

        case .notFound(let reference):
            return "No intent matches '\(reference)'."

        case .ambiguous(let reference, let matches):
            return "'\(reference)' matches \(matches.count) intents: \(matches.prefix(5).joined(separator: ", ")). Use more of the id."

        case .unknownStatus(let name):
            return "Unknown status '\(name)'. Use: \(Intents.Intent.Status.allCases.map(\.rawValue).joined(separator: ", "))."

        case .unknownDecision(let name):
            return "Unknown decision '\(name)'. Use: approve, deny, cancel or expire."

        case .executionFailed(let id):
            return "Intent \(id) ran and failed; its execution record says why."
        }
    }
}
