import Agentic
import AgenticRuntime

/// Optional application contract for trusted, per-session dependencies.
/// Domain installation remains completely macro-derived.
public protocol AgenticSessionServicesProviding: AgenticApplicationProviding, SendableMetatype {
    static func services(for sessionID: String?) throws -> ToolServices
}

public enum AgenticSessionServices {
    public struct Factory: Sendable {
        private let provider: (any AgenticSessionServicesProviding.Type)?

        public init<Application: AgenticApplicationProviding>(
            _ application: Application.Type
        ) {
            provider = application as? any AgenticSessionServicesProviding.Type
        }

        public func resolve(sessionID: String? = nil) throws -> ToolServices {
            guard let provider else { return .init() }
            return try provider.services(for: sessionID)
        }
    }

    public static func resolve<Application: AgenticApplicationProviding>(
        _ application: Application.Type,
        sessionID: String? = nil
    ) throws -> ToolServices {
        guard let providing = application as? any AgenticSessionServicesProviding.Type else {
            return .init()
        }
        return try providing.services(for: sessionID)
    }
}
