import Agentic
import AgenticHost
import AgenticRuntime
import Arguments
import Writers

public struct AgenticRunShellOptions: Sendable, ArgumentParsed {
    public typealias ArgumentPayload = Payload
    public let workspace: AgenticRuntimeWorkspaceConfiguration

    public init(arguments: Payload) throws {
        workspace = try arguments.workspace.configuration()
    }

    public struct Payload: ArgumentGroup {
        @Group("workspace")
        public var workspace: AgenticRuntimeWorkspaceArguments

        public init() {}
    }
}

/// Interactive command shell. It never instantiates the full-screen TUI.
public enum AgenticRunShellCommand<Application: AgenticApplicationProviding>: ParsedArgumentCommand {
    public typealias Options = AgenticRunShellOptions
    public static var name: String { "run" }

    public static func run(_ options: Options, invocation: ParsedInvocation) async throws {
        _ = invocation
        let runtime = try await AgenticRuntime.resolve(Application.self)
        let workspace = try AgenticRuntimeWorkspace.resolve(options.workspace)
        let serviceFactory = AgenticSessionServices.Factory(Application.self)
        let service: any AgentHost.Service = AgentHost.Local(
            runtime: runtime,
            workspace: workspace,
            mutations: .coordinated(StandardMutationCoordinator()),
            logs: try .home(AgentHomeLocator().resolveHome()),
            services: { id in try serviceFactory.resolve(sessionID: id.rawValue) }
        )
        let shell = AgenticRunShell(
            service: service,
            agents: runtime.agents.definitions.map(\.identifier),
            workspace: options.workspace.path
        )
        await shell.run()
    }
}
