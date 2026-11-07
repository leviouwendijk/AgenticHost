import Agentic
import AgenticHost
import AgenticStandard
import AgenticRuntime
import Foundation
import TestFlows

private actor SessionServiceProbe {}

private final class SessionServiceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var created: [String] = []

    func construct(for session: String) throws -> ToolServices {
        lock.withLock {
            created.append(session)
        }
        return try ToolServices().inserting(SessionServiceProbe())
    }

    func snapshot() -> [String] {
        lock.withLock { created }
    }
}

private enum SessionServiceTestFailure: Error {
    case invalid_lifecycle
}

enum AgenticHostSessionServicesFlow {
    static func run() async throws -> [TestDiagnostic] {
        let application = Agentic.application("session-service-lifecycle-test") {
            install(Standard.self)
        }
        let runtime = try await AgenticRuntime(application: application)
        let counter = SessionServiceCounter()
        let host = AgentHost.Local(runtime: runtime, services: { id in
            try counter.construct(for: id.rawValue)
        })
        _ = try await host.start(.init(id: "alpha"))
        _ = try await host.start(.init(id: "beta"))
        let first = counter.snapshot()
        guard first == ["alpha", "beta"] else {
            throw SessionServiceTestFailure.invalid_lifecycle
        }
        _ = try await host.sessions()
        guard counter.snapshot() == first else {
            throw SessionServiceTestFailure.invalid_lifecycle
        }
        return [.field("created_once_per_session", "true")]
    }
}
