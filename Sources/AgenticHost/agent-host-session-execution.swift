import Agentic
import AgenticModels
import AgenticRuntime

public extension AgentHost.Session {
    struct Execution:
        Sendable,
        Codable,
        Hashable
    {
        public var modelSelection: AgentModelSelection?
        public var system: String?
        /// Immutable provenance of the exact authored system instructions.
        /// Older transports can still send the plain `system` text.
        public var instructions: InstructionSnapshot?
        public var invocationOptions: AgentModelInvocationOptions
        public var availableCapabilities: AgentCapabilitySet?
        public var visibleCapabilities: AgentCapabilitySet?
        public var configuration: AgentRunner.Configuration

        public init(
            modelSelection: AgentModelSelection? = nil,
            system: String? = nil,
            instructions: InstructionSnapshot? = nil,
            invocationOptions: AgentModelInvocationOptions = .init(),
            availableCapabilities: AgentCapabilitySet? = nil,
            visibleCapabilities: AgentCapabilitySet? = nil,
            configuration: AgentRunner.Configuration = .init()
        ) {
            self.modelSelection = modelSelection
            self.system = system
            self.instructions = instructions
            self.invocationOptions = invocationOptions
            self.availableCapabilities = availableCapabilities
            self.visibleCapabilities = visibleCapabilities
            self.configuration = configuration
        }
    }
}
