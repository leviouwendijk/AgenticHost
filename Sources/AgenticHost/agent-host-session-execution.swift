import Agentic
import AgenticModels
import AgenticRuntime

public extension AgentHost.Session {
    struct Execution:
        Sendable,
        Codable,
        Hashable
    {
        public var modelSelection: AgentModelSelection
        public var system: String?
        public var invocationOptions: AgentModelInvocationOptions
        public var availableCapabilities: AgentCapabilitySet?
        public var visibleCapabilities: AgentCapabilitySet?
        public var configuration: AgentRunnerConfiguration

        public init(
            modelSelection: AgentModelSelection = .executor,
            system: String? = nil,
            invocationOptions: AgentModelInvocationOptions = .init(),
            availableCapabilities: AgentCapabilitySet? = nil,
            visibleCapabilities: AgentCapabilitySet? = nil,
            configuration: AgentRunnerConfiguration = .init()
        ) {
            self.modelSelection = modelSelection
            self.system = system
            self.invocationOptions = invocationOptions
            self.availableCapabilities = availableCapabilities
            self.visibleCapabilities = visibleCapabilities
            self.configuration = configuration
        }
    }
}
