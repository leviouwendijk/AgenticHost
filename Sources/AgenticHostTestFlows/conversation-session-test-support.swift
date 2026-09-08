import AgenticCommandLine
import AgenticHost
import AgenticRuntime

func makeLocalConversationSession(
    runtime: AgenticRuntime,
    workspacePath: String,
    sessionID: String? = nil
) throws -> AgenticConversationSession {
    let workspace = try AgenticRuntimeWorkspace.resolve(
        AgenticRuntimeWorkspaceConfiguration(
            path: workspacePath
        )
    )
    let service: any AgentHost.Service = AgentHost.Local(
        runtime: runtime,
        workspace: workspace
    )

    return try AgenticConversationSession(
        runtime: runtime,
        workspace: workspace,
        service: service,
        sessionID: sessionID
    )
}
