import Agentic
import AgenticPrograms

public extension AgentHost {
    struct Capabilities:
        Sendable,
        Codable
    {
        public var models: [Model]
        public var skills: [Skill]
        public var programs: [AgentProgramDescriptor]
        public var tools: ToolCatalog

        public init(
            models: [Model] = [],
            skills: [Skill] = [],
            programs: [AgentProgramDescriptor] = [],
            tools: ToolCatalog = .init()
        ) {
            self.models = models
            self.skills = skills
            self.programs = programs
            self.tools = tools
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
        public var requiredToolIdentifiers: [AgentToolIdentifier]
        public var optionalToolIdentifiers: [AgentToolIdentifier]

        public init(
            id: AgentSkillIdentifier,
            title: String,
            summary: String,
            contextText: String,
            toolNames: [String],
            requiredToolIdentifiers: [AgentToolIdentifier] = [],
            optionalToolIdentifiers: [AgentToolIdentifier] = []
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
        public var defaultExposedIdentifiers: [AgentToolIdentifier]
        public var modelFacingIdentifiers: [AgentToolIdentifier]

        public init(
            collections: [ToolCollection] = [],
            defaultExposedIdentifiers: [AgentToolIdentifier] = [],
            modelFacingIdentifiers: [AgentToolIdentifier] = []
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
        public var id: AgentToolIdentifier
        public var title: String
        public var summary: String

        public init(
            id: AgentToolIdentifier,
            title: String,
            summary: String
        ) {
            self.id = id
            self.title = title
            self.summary = summary
        }
    }
}
