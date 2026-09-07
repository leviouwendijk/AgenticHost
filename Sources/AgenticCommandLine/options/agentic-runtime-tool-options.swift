import AgenticRuntime
import Arguments
import Foundation

public struct AgenticRuntimeToolDescribeOptions:
    Sendable,
    ArgumentParsed
{
    public typealias ArgumentPayload = Payload

    public let name: String

    public init(
        arguments: Payload
    ) throws {
        let name = arguments.name
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !name.isEmpty else {
            throw AgenticRuntimeCommandError
                .blankToolName
        }

        self.name = name
    }

    public struct Payload:
        ArgumentGroup
    {
        @Arg(
            "name",
            help: "Registered Agentic tool name.",
            default: ""
        )
        public var name: String

        public init() {}
    }
}

public struct AgenticRuntimeToolCallOptions:
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
            help: "Optional host-call session identifier."
        )
        public var sessionID: String?

        public init() {}
    }
}
