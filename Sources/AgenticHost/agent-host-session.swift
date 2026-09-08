import AgenticRuntime

public extension AgentHost {
    enum Session {}
}

public extension AgentHost.Session {
    struct ID:
        RawRepresentable,
        Sendable,
        Codable,
        Hashable,
        ExpressibleByStringLiteral
    {
        public let rawValue: String

        public init(
            rawValue: String
        ) {
            self.rawValue = rawValue
        }

        public init(
            _ rawValue: String
        ) {
            self.init(
                rawValue: rawValue
            )
        }

        public init(
            stringLiteral value: String
        ) {
            self.init(
                rawValue: value
            )
        }
    }

    struct Start:
        Sendable,
        Codable,
        Hashable
    {
        public var id: ID?
        public var title: String?
        public var metadata: [String: String]

        public init(
            id: ID? = nil,
            title: String? = nil,
            metadata: [String: String] = [:]
        ) {
            self.id = id
            self.title = title
            self.metadata = metadata
        }
    }

    struct Summary:
        Sendable,
        Codable,
        Hashable
    {
        public var id: ID
        public var title: String?
        public var interaction: AgentInteraction.Request?
        public var metadata: [String: String]

        public init(
            id: ID,
            title: String? = nil,
            interaction: AgentInteraction.Request? = nil,
            metadata: [String: String] = [:]
        ) {
            self.id = id
            self.title = title
            self.interaction = interaction
            self.metadata = metadata
        }
    }

    struct Submission:
        Sendable,
        Codable,
        Hashable
    {
        public var session: ID
        public var prompt: String
        public var execution: Execution
        public var metadata: [String: String]

        public init(
            session: ID,
            prompt: String,
            execution: Execution = .init(),
            metadata: [String: String] = [:]
        ) {
            self.session = session
            self.prompt = prompt
            self.execution = execution
            self.metadata = metadata
        }
    }
}
