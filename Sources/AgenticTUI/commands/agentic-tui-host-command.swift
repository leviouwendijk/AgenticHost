import Agentic
import AgenticCommandLine
import AgenticRuntime
import Arguments

/// Interactive host command group; headless manifest and bridge reuse their
/// original command implementations and authorization contracts.
public enum AgenticTUIHostCommand<
    Application: AgenticApplicationProviding
>: ArgumentCommand {
    public static var name: String { "host" }
    public static var defaultChild: Console.Type { Console.self }

    public static var children: [ArgumentCommandType] {
        [
            Console.self,
            Help.self,
            AgenticHostCommand<Application>.Manifest.self,
            AgenticHostCommand<Application>.Bridge.self,
        ]
    }

    public enum Console:
        ParsedArgumentCommand
    {
        public typealias Options = HostOptions

        public static var name: String {
            "console"
        }

        public static func run(
            _ options: Options,
            invocation: ParsedInvocation
        ) async throws {
            _ = invocation

            let runtime = try await AgenticRuntime.resolve(
                Application.self
            )
            let host = try runtime.host(
                workspace: options.workspace,
                sessionID: options.sessionID
            )

            try await HostConsole.run(
                host: host,
                context: options.workspace.path
            )
        }
    }

    public enum Help: RunnableArgumentCommand {
        public static var name: String { "help" }

        public static func run(
            _ invocation: ParsedInvocation
        ) async throws {
            _ = invocation
            print(
                ArgumentHelpRenderer().render(
                    command: try AgenticTUIHostCommand<Application>.spec()
                )
            )
        }
    }
}
