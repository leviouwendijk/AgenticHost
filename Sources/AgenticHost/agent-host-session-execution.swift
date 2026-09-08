import Agentic
import AgenticModels
import AgenticRuntime

public extension AgentHost.Session {
    struct Execution:
        Sendable,
        Codable,
        Hashable
    {
        public var modelProfileID: AgentModelProfileIdentifier?
        public var system: String?
        public var invocationOptions: AgentModelInvocationOptions
        public var configuration: AgentRunnerConfiguration

        public init(
            modelProfileID: AgentModelProfileIdentifier? = nil,
            system: String? = nil,
            invocationOptions: AgentModelInvocationOptions = .init(),
            configuration: AgentRunnerConfiguration = .init()
        ) {
            self.modelProfileID = modelProfileID
            self.system = system
            self.invocationOptions = invocationOptions
            self.configuration = configuration
        }
    }
}
