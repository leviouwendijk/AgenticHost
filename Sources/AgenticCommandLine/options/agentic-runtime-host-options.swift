import AgenticRuntime
import Arguments
import Foundation

public struct HostOptions:
    Sendable,
    ArgumentParsed
{
    public typealias ArgumentPayload = Payload

    public let workspace:
        AgenticRuntimeWorkspaceConfiguration
    public let sessionID: String?

    public init(
        arguments: Payload
    ) throws {
        self.workspace =
            try arguments.workspace.configuration()

        let sessionID = arguments.sessionID?
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        self.sessionID = sessionID.flatMap {
            $0.isEmpty ? nil : $0
        }
    }

    public struct Payload:
        ArgumentGroup
    {
        @Group("workspace")
        public var workspace:
            AgenticRuntimeWorkspaceArguments

        @Opt(
            "session",
            help: "Optional persistent host session identifier."
        )
        public var sessionID: String?

        public init() {}
    }
}

public struct AgenticRuntimeHostManifestOptions:
    Sendable,
    ArgumentParsed
{
    public typealias ArgumentPayload = Payload

    public let workspace:
        AgenticRuntimeWorkspaceConfiguration
    public let sessionID: String?
    public let copy: Bool

    public init(
        arguments: Payload
    ) throws {
        self.workspace =
            try arguments.workspace.configuration()

        let sessionID = arguments.sessionID?
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        self.sessionID = sessionID.flatMap {
            $0.isEmpty ? nil : $0
        }
        self.copy = arguments.copy
    }

    public struct Payload:
        ArgumentGroup
    {
        @Group("workspace")
        public var workspace:
            AgenticRuntimeWorkspaceArguments

        @Opt(
            "session",
            help: "Optional host session identifier included in the capability manifest."
        )
        public var sessionID: String?

        @Flag(
            "copy",
            help: "Copy the capability manifest to the clipboard instead of printing it."
        )
        public var copy: Bool

        public init() {}
    }
}

public struct AgenticRuntimeHostBridgeOptions:
    Sendable,
    ArgumentParsed
{
    public typealias ArgumentPayload = Payload

    public let workspace:
        AgenticRuntimeWorkspaceConfiguration
    public let sessionID: String?
    public let standardInput: Bool

    public init(
        arguments: Payload
    ) throws {
        self.workspace =
            try arguments.workspace.configuration()

        let sessionID = arguments.sessionID?
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        self.sessionID = sessionID.flatMap {
            $0.isEmpty ? nil : $0
        }
        self.standardInput = arguments.standardInput
    }

    public struct Payload:
        ArgumentGroup
    {
        @Group("workspace")
        public var workspace:
            AgenticRuntimeWorkspaceArguments

        @Opt(
            "session",
            help: "Optional host session identifier used for governed tool invocation."
        )
        public var sessionID: String?

        @Flag(
            "stdin",
            help: "Read tool-host invocation JSON from standard input and write the result to standard output. Accepts one AgentToolCall, an AgentToolCall array, or an AgentToolPlan."
        )
        public var standardInput: Bool

        public init() {}
    }
}
