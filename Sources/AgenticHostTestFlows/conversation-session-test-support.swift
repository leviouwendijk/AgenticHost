import AgenticCommandLine
import AgenticHost
import AgenticRuntime

func makeLocalConversationSession(
    runtime: AgenticRuntime,
    workspacePath: String,
    sessionID: String? = nil
) async throws -> AgenticConversationSession {
    let workspace = try AgenticRuntimeWorkspace.resolve(
        AgenticRuntimeWorkspaceConfiguration(
            path: workspacePath
        )
    )
    let service: any AgentHost.Service = AgentHost.Local(
        runtime: runtime,
        workspace: workspace
    )
    let capabilities = try await service.capabilities()

    return try AgenticConversationSession(
        workspace: workspace.rootURL.path,
        service: service,
        capabilities: capabilities,
        sessionID: sessionID
    )
}
