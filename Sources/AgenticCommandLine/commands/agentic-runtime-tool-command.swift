import AgenticHost
import AgenticInterfaces
import AgenticRuntime
import Arguments
import Terminal

public enum AgenticRuntimeToolCommand<
    Application: AgenticApplicationProviding
>:
    ArgumentCommand
{
    public static var name: String {
        "tool"
    }

    public static var defaultChild: Help.Type {
        Help.self
    }

    public static var children: [ArgumentCommandType] {
        [
            Help.self,
            List.self,
            Describe.self,
            Preflight.self,
            Invoke.self,
        ]
    }

    static func runtime() async throws -> AgenticRuntime {
        try await .resolve(
            Application.self
        )
    }

    public enum Help:
        RunnableArgumentCommand
    {
        public static var name: String {
            "help"
        }

        public static func run(
            _ invocation: ParsedInvocation
        ) async throws {
            _ = invocation

            print(
                ArgumentHelpRenderer().render(
                    command:
                        try AgenticRuntimeToolCommand<Application>.spec()
                )
            )
        }
    }

    public enum List:
        RunnableArgumentCommand
    {
        public static var name: String {
            "list"
        }

        public static func run(
            _ invocation: ParsedInvocation
        ) async throws {
            _ = invocation

            let runtime = try await AgenticRuntimeToolCommand<Application>
                .runtime()
            let host = try runtime.host()

            try AgenticRuntimeCommandIO.write(
                host.list()
            )
        }
    }

    public enum Describe:
        ParsedArgumentCommand
    {
        public typealias Options =
            AgenticRuntimeToolDescribeOptions

        public static var name: String {
            "describe"
        }

        public static func run(
            _ options: Options,
            invocation: ParsedInvocation
        ) async throws {
            _ = invocation

            let runtime = try await AgenticRuntimeToolCommand<Application>
                .runtime()
            let host = try runtime.host()

            try AgenticRuntimeCommandIO.write(
                try host.describe(
                    options.name
                )
            )
        }
    }

    public enum Preflight:
        ParsedArgumentCommand
    {
        public typealias Options =
            AgenticRuntimeToolCallOptions

        public static var name: String {
            "preflight"
        }

        public static func run(
            _ options: Options,
            invocation: ParsedInvocation
        ) async throws {
            _ = invocation

            let call = try AgenticRuntimeCommandIO
                .readToolCall()
            let runtime = try await AgenticRuntimeToolCommand<Application>
                .runtime()
            let host = try runtime.host(
                workspace: options.workspace,
                sessionID: options.sessionID
            )

            try AgenticRuntimeCommandIO.write(
                try await host.preflight(
                    call
                )
            )
        }
    }

    public enum Invoke:
        ParsedArgumentCommand
    {
        public typealias Options =
            AgenticRuntimeToolCallOptions

        public static var name: String {
            "invoke"
        }

        public static func run(
            _ options: Options,
            invocation: ParsedInvocation
        ) async throws {
            _ = invocation

            let call = try AgenticRuntimeCommandIO
                .readToolCall()

            let approvalPicker: TerminalApprovalPicker?

            if Terminal.io.stdin.reconnect(
                to: .terminal
            ) {
                approvalPicker = TerminalApprovalPicker()
            } else {
                approvalPicker = nil
            }

            let runtime = try await AgenticRuntimeToolCommand<Application>
                .runtime()
            let host = try runtime.host(
                workspace: options.workspace,
                sessionID: options.sessionID,
                approvalHandler: approvalPicker
            )

            try AgenticRuntimeCommandIO.write(
                try await host.invoke(
                    call
                )
            )
        }
    }
}
