import Agentic

public extension AgentHost {
    struct Capabilities:
        Sendable,
        Codable
    {
        public var models: [Model]
        public var instructions: [InstructionDefinition]
        public var programs: [ProgramDefinition]
        /// Read-only catalog projection. Neither grants nor changes authority.
        public var catalogEntries: [CatalogEntry]
        public var installedCapabilities: AgentCapabilitySet
        public var defaultExecution: AgentHost.Session.Execution

        public init(
            models: [Model] = [],
            instructions: [InstructionDefinition] = [],
            programs: [ProgramDefinition] = [],
            catalogEntries: [CatalogEntry] = [],
            installedCapabilities: AgentCapabilitySet = .none,
            defaultExecution: AgentHost.Session.Execution = .init()
        ) {
            self.models = models
            self.instructions = instructions
            self.programs = programs
            self.catalogEntries = catalogEntries
            self.installedCapabilities = installedCapabilities
            self.defaultExecution = defaultExecution
        }
    }
}

public extension AgentHost.Capabilities {
    struct Model:
        Sendable,
        Codable
    {
        public var id: AgentModelProfileIdentifier
        public var model: String
        public var gatewayIdentifier: AgentModelGatewayIdentifier
        public var title: String
        public var supportsStreaming: Bool

        public init(
            id: AgentModelProfileIdentifier,
            model: String,
            gatewayIdentifier: AgentModelGatewayIdentifier,
            title: String,
            supportsStreaming: Bool
        ) {
            self.id = id
            self.model = model
            self.gatewayIdentifier = gatewayIdentifier
            self.title = title
            self.supportsStreaming = supportsStreaming
        }
    }


}
