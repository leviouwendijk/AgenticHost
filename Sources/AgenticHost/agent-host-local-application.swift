import Agentic
import AgenticRuntime
import Foundation
import Writers

public extension AgentHost.Local {
    /// A local host as an application runs it: the resolved workspace, the
    /// home's session logs, settings and tasks, coordinated mutations, and
    /// the application's per-session services (such as scheduling's
    /// calendars). Every interface starts here, so the terminal and the
    /// desktop app run the same host.
    struct Launch: Sendable {
        public let runtime: AgenticRuntime
        public let host: AgentHost.Local
        /// The workspace's absolute root path.
        public let workspacePath: String
    }

    static func launch<Application: AgenticApplicationProviding>(
        _ application: Application.Type,
        workspace configuration: AgenticRuntimeWorkspaceConfiguration
    ) async throws -> Launch {
        let runtime = try await AgenticRuntime.resolve(application)
        let workspace = try AgenticRuntimeWorkspace.resolve(configuration)
        // The resolved root, never the raw configuration: "." renders as a path.
        let workspacePath = workspace
            .root(identifier: workspace.defaultRootIdentifier ?? workspace.roots[0].id)
            .map(\.rootPath)
            ?? configuration.path
        let serviceFactory = AgenticSessionServices.Factory(Application.self)
        let home = AgentHomeLocator().resolveHome()
        let host = AgentHost.Local(
            runtime: runtime,
            workspace: workspace,
            mutations: .coordinated(StandardMutationCoordinator()),
            logs: try .home(home),
            publication: try home.settings().mutations.publication,
            workers: try home.settings().mutations.workers,
            tasks: .home(home),
            pathSettings: {
                .init(paths: try home.settings().paths, scopes: try home.pathScopes())
            },
            services: { sessionID in
                try serviceFactory.resolve(sessionID: sessionID.rawValue)
            }
        )
        return .init(runtime: runtime, host: host, workspacePath: workspacePath)
    }
}
