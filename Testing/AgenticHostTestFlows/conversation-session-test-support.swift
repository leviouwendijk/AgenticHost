import AgenticCommandLine
import AgenticHost
import AgenticRuntime
import Workspace

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
    let workspaceContext = try workspace.context()
    let service: any AgentHost.Service = AgentHost.Local(
        runtime: runtime,
        workspace: workspace
    )
    let capabilities = try await service.capabilities()

    return try AgenticConversationSession(
        workspace: workspaceContext.rootURL.path,
        service: service,
        capabilities: capabilities,
        sessionID: sessionID
    )
}