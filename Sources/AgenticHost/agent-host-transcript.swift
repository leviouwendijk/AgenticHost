import Agentic

public extension AgentHost {
    struct Transcript:
        Sendable,
        Codable
    {
        public var session: Session.ID
        public var messages: [AgentMessage]

        public init(
            session: Session.ID,
            messages: [AgentMessage]
        ) {
            self.session = session
            self.messages = messages
        }
    }
}
