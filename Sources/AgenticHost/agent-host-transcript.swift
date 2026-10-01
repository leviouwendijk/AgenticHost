import Agentic

public extension AgentHost {
    struct Transcript:
        Sendable,
        Codable
    {
        public var session: Session.ID
        public var messages: [Message]

        public init(
            session: Session.ID,
            messages: [Message]
        ) {
            self.session = session
            self.messages = messages
        }
    }
}
