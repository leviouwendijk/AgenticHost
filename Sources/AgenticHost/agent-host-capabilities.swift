import Agentic

public extension AgentHost {
    struct Capabilities:
        Sendable,
        Codable
    {
        public var models: [Model]
        public var skills: [Skill]
        public var programs: [ProgramDefinition]
        public var tools: ToolCatalog
        public var defaultExecution: AgentHost.Session.Execution

        public init(
            models: [Model] = [],
            skills: [Skill] = [],
            programs: [ProgramDefinition] = [],
            tools: ToolCatalog = .init(),
            defaultExecution: AgentHost.Session.Execution = .init()
        ) {
            self.models = models
            self.skills = skills
            self.programs = programs
            self.tools = tools
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

    struct Skill:
        Sendable,
        Codable
    {
        public var id: AgentSkillIdentifier
        public var title: String
        public var summary: String
        public var contextText: String
        public var toolNames: [String]
        public var requiredToolIdentifiers: [ToolIdentifier]
        public var optionalToolIdentifiers: [ToolIdentifier]

        public init(
            id: AgentSkillIdentifier,
            title: String,
            summary: String,
            contextText: String,
            toolNames: [String],
            requiredToolIdentifiers: [ToolIdentifier] = [],
            optionalToolIdentifiers: [ToolIdentifier] = []
        ) {
            self.id = id
            self.title = title
            self.summary = summary
            self.contextText = contextText
            self.toolNames = toolNames
            self.requiredToolIdentifiers = requiredToolIdentifiers
            self.optionalToolIdentifiers = optionalToolIdentifiers
        }
    }

    struct ToolCatalog:
        Sendable,
        Codable
    {
        public var collections: [ToolCollection]
        public var defaultExposedIdentifiers: [ToolIdentifier]
        public var modelFacingIdentifiers: [ToolIdentifier]

        public init(
            collections: [ToolCollection] = [],
            defaultExposedIdentifiers: [ToolIdentifier] = [],
            modelFacingIdentifiers: [ToolIdentifier] = []
        ) {
            self.collections = collections
            self.defaultExposedIdentifiers = defaultExposedIdentifiers
            self.modelFacingIdentifiers = modelFacingIdentifiers
        }
    }

    struct ToolCollection:
        Sendable,
        Codable
    {
        public var id: String
        public var title: String
        public var tools: [Tool]

        public init(
            id: String,
            title: String,
            tools: [Tool]
        ) {
            self.id = id
            self.title = title
            self.tools = tools
        }
    }

    struct Tool:
        Sendable,
        Codable
    {
        public var id: ToolIdentifier
        public var title: String
        public var summary: String

        public init(
            id: ToolIdentifier,
            title: String,
            summary: String
        ) {
            self.id = id
            self.title = title
            self.summary = summary
        }
    }
}
