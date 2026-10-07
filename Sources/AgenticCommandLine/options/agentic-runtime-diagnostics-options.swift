import Agentic
import Arguments
import Foundation

public struct AgenticRuntimeDiagnosticsOptions:
    Sendable,
    ArgumentParsed
{
    public typealias ArgumentPayload = Payload

    public let agent: AgentIdentifier?
    public let verbose: Bool
    public let json: Bool

    public init(
        arguments: Payload
    ) throws {
        let agent = arguments.agent?
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        self.agent = agent.flatMap { value in
            value.isEmpty
                ? nil
                : AgentIdentifier(
                    rawValue: value
                )
        }
        self.verbose = arguments.verbose
        self.json = arguments.json
    }

    public struct Payload:
        ArgumentGroup
    {
        @Opt(
            "agent",
            help: "Restrict diagnostics to one installed Agent identifier."
        )
        public var agent: String?

        @Flag(
            "verbose",
            help: "Include capability identifiers in human-readable output."
        )
        public var verbose: Bool

        @Flag(
            "json",
            help: "Encode diagnostics as JSON instead of human-readable text."
        )
        public var json: Bool

        public init() {}
    }
}
