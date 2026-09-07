import Agentic
import AgenticHost
import AgenticRuntime
import Arguments
import Foundation

public struct AgenticRunCommandArguments: Sendable, Codable, Hashable {
    public var modeID: AgenticModeIdentifier
    public var prompt: String
    public var system: String?
    public var metadata: [String: String]

    public init(
        modeID: AgenticModeIdentifier = .coder,
        prompt: String,
        system: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.modeID = modeID
        self.prompt = prompt
        self.system = system
        self.metadata = metadata
    }

    public func command() -> AgenticRunCommand {
        .init(
            modeID: modeID,
            prompt: prompt,
            system: system,
            metadata: metadata
        )
    }
}

public struct AgenticRunCommandInvocation: Sendable, Codable, Hashable {
    public var arguments: AgenticRunCommandArguments
    public var command: AgenticRunCommand

    public init(
        arguments: AgenticRunCommandArguments,
        command: AgenticRunCommand
    ) {
        self.arguments = arguments
        self.command = command
    }
}

public enum AgenticRunCommandArgumentParserError: Error, Sendable, LocalizedError, Hashable {
    case missingPrompt
    case unknownMode(String, available: [String])
    case invalidMetadata(String)

    public var errorDescription: String? {
        switch self {
        case .missingPrompt:
            return "Missing prompt for agentic run command."

        case .unknownMode(let mode, let available):
            return "Unknown mode '\(mode)'. Available modes: \(available.sorted().joined(separator: ", "))."

        case .invalidMetadata(let value):
            return "Invalid metadata entry '\(value)'. Expected key=value."
        }
    }
}

public struct AgenticRunCommandArgumentParser: Sendable {
    public var catalog: ModeCatalog

    public init(
        catalog: ModeCatalog
    ) {
        self.catalog = catalog
    }

    public static func standard() throws -> Self {
        try .init(
            catalog: .standard
        )
    }

    public func parse(
        _ argv: [String]
    ) throws -> AgenticRunCommandInvocation {
        let invocation = try Arguments.parse(
            normalizedArgv(
                argv
            ),
            spec: spec()
        )

        let parsed = try arguments(
            from: invocation
        )

        return .init(
            arguments: parsed,
            command: parsed.command()
        )
    }

    public func parseCommand(
        _ argv: [String]
    ) throws -> AgenticRunCommand {
        try parse(
            argv
        ).command
    }
}

private extension AgenticRunCommandArgumentParser {
    func spec() throws -> CommandSpec {
        try cmd("agentic") {
            defaultChild("run")

            try cmd("run") {
                about("Run one Agentic prompt through a selected mode.")

                opt(
                    "mode",
                    as: String.self,
                    help: "Mode identifier. Defaults to coder."
                )

                opt(
                    "system",
                    as: String.self,
                    help: "Optional system instruction."
                )

                opt(
                    "metadata",
                    as: String.self,
                    take: .repeating,
                    help: "Metadata entry in key=value form. Repeatable."
                )

                arg(
                    "prompt",
                    as: String.self,
                    arity: .optional,
                    help: "Prompt to run."
                )
            }
        }
    }

    func normalizedArgv(
        _ argv: [String]
    ) -> [String] {
        if argv.first == "agentic" {
            guard argv.dropFirst().first != "run" else {
                return argv
            }

            return [
                "agentic",
                "run"
            ] + Array(
                argv.dropFirst()
            )
        }

        if argv.first == "run" {
            return [
                "agentic"
            ] + argv
        }

        return [
            "agentic",
            "run"
        ] + argv
    }

    func arguments(
        from invocation: ParsedInvocation
    ) throws -> AgenticRunCommandArguments {
        let modeRaw = try invocation.value(
            "mode",
            as: String.self
        ) ?? AgenticModeIdentifier.coder.rawValue

        let modeID = try validatedModeID(
            modeRaw
        )

        guard let prompt = try invocation.value(
            "prompt",
            as: String.self
        )?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
              !prompt.isEmpty
        else {
            throw AgenticRunCommandArgumentParserError.missingPrompt
        }

        let system = try invocation.value(
            "system",
            as: String.self
        )

        let metadata = try metadataDictionary(
            from: invocation.values(
                "metadata",
                as: String.self
            )
        )

        return .init(
            modeID: modeID,
            prompt: prompt,
            system: system,
            metadata: metadata
        )
    }

    func validatedModeID(
        _ rawValue: String
    ) throws -> AgenticModeIdentifier {
        let modeID = AgenticModeIdentifier(
            rawValue: rawValue
        )
        let available = catalog.all.map(\.id)

        guard available.contains(
            modeID
        ) else {
            throw AgenticRunCommandArgumentParserError.unknownMode(
                rawValue,
                available: available.map(\.rawValue)
            )
        }

        return modeID
    }

    func metadataDictionary(
        from entries: [String]
    ) throws -> [String: String] {
        var metadata: [String: String] = [:]

        for entry in entries {
            let parts = entry.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )

            guard parts.count == 2,
                  !parts[0].isEmpty
            else {
                throw AgenticRunCommandArgumentParserError.invalidMetadata(
                    entry
                )
            }

            metadata[String(parts[0])] = String(parts[1])
        }

        return metadata
    }
}
