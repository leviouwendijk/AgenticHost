
/// Serializable catalog read model. An entry describes identity and location,
/// not installation or execution authority. Installed entries are separately
/// bounded by `installedCapabilities` and the launch's capability state.
public extension AgentHost.Capabilities {
    struct CatalogEntry: Sendable, Codable, Hashable, Identifiable {
        public enum Kind: String, Sendable, Codable, Hashable, CaseIterable {
            case tool
            case program
            case inference
            case agent
            case instruction
        }

        public let kind: Kind
        public let identifier: String
        public let namespace: String?
        public let title: String
        public let summary: String

        public var id: String { "\(kind.rawValue):\(identifier)" }

        public init(
            kind: Kind,
            identifier: String,
            namespace: String? = nil,
            title: String,
            summary: String
        ) {
            self.kind = kind
            self.identifier = identifier
            self.namespace = namespace
            self.title = title
            self.summary = summary
        }
    }
}
