import Agentic
import AgenticExecution
import Primitives

public extension AgentHost {
    struct ProgramInvocation:
        Sendable,
        Codable
    {
        public var program: ProgramIdentifier
        public var input: JSONValue
        public var realization: JSONValue?
        public var autonomyMode: AutonomyMode
        public var metadata: [String: String]

        public init(
            program: ProgramIdentifier,
            input: JSONValue,
            realization: JSONValue? = nil,
            autonomyMode: AutonomyMode = .auto_observe,
            metadata: [String: String] = [:]
        ) {
            self.program = program
            self.input = input
            self.realization = realization
            self.autonomyMode = autonomyMode
            self.metadata = metadata
        }
    }
}
