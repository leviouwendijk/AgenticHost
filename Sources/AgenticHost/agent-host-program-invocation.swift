import AgenticPrograms
import Primitives

public extension AgentHost {
    struct ProgramInvocation:
        Sendable,
        Codable
    {
        public var program: AgentProgramIdentifier
        public var input: JSONValue
        public var realization: JSONValue?
        public var metadata: [String: String]

        public init(
            program: AgentProgramIdentifier,
            input: JSONValue,
            realization: JSONValue? = nil,
            metadata: [String: String] = [:]
        ) {
            self.program = program
            self.input = input
            self.realization = realization
            self.metadata = metadata
        }
    }
}
