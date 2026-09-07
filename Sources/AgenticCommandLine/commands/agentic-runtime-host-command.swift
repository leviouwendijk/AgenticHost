import Agentic
import AgenticHost
import AgenticInterfaces
import AgenticRuntime
import Arguments
import Clipboard
import Foundation
import Terminal

public enum AgenticRuntimeHostCommand<
    Application: AgenticApplicationProviding
>:
    ArgumentCommand
{
    public static var name: String {
        "host"
    }

    public static var defaultChild: Console.Type {
        Console.self
    }

    public static var children: [ArgumentCommandType] {
        [
            Console.self,
            Help.self,
            Manifest.self,
            Bridge.self,
        ]
    }

    static func runtime() async throws -> AgenticRuntime {
        try await .resolve(
            Application.self
        )
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

            let runtime = try await AgenticRuntimeHostCommand<Application>
                .runtime()
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
                        try AgenticRuntimeHostCommand<Application>.spec()
                )
            )
        }
    }

    public enum Manifest:
        ParsedArgumentCommand
    {
        public typealias Options =
            AgenticRuntimeHostManifestOptions

        public static var name: String {
            "manifest"
        }

        public static func run(
            _ options: Options,
            invocation: ParsedInvocation
        ) async throws {
            _ = invocation

            let runtime = try await AgenticRuntimeHostCommand<Application>
                .runtime()
            let host = try runtime.host(
                workspace: options.workspace,
                sessionID: options.sessionID
            )
            let text = try host
                .capabilityManifestText()

            if options.copy {
                guard Clipboard.system.write(
                    text
                ) else {
                    throw AgenticRuntimeCommandError
                        .clipboardWriteFailed
                }

                return
            }

            print(
                text
            )
        }
    }

    public enum Bridge:
        ParsedArgumentCommand
    {
        public typealias Options =
            AgenticRuntimeHostBridgeOptions

        public static var name: String {
            "bridge"
        }

        public static func run(
            _ options: Options,
            invocation: ParsedInvocation
        ) async throws {
            _ = invocation

            let inputData: Data

            if options.standardInput {
                inputData =
                    try AgenticRuntimeCommandIO
                        .readStandardInput()
            } else {
                guard let text = Clipboard.system.read(),
                      !text.trimmingCharacters(
                        in: .whitespacesAndNewlines
                      ).isEmpty
                else {
                    throw AgenticRuntimeCommandError
                        .missingClipboardInput
                }

                inputData =
                    Data(
                        text.utf8
                    )
            }

            let approvalPicker: TerminalApprovalPicker?

            if Terminal.io.stdin.reconnect(
                to: .terminal
            ) {
                approvalPicker = TerminalApprovalPicker()
            } else {
                approvalPicker = nil
            }

            let runtime = try await AgenticRuntimeHostCommand<Application>
                .runtime()
            let host = try runtime.host(
                workspace: options.workspace,
                sessionID: options.sessionID,
                approvalHandler: approvalPicker
            )
            let request =
                try host.decodeInvocationRequest(
                    inputData
                )
            let recoveryPicker: AgenticRuntimeToolPlanRecoveryPicker?

            if approvalPicker == nil {
                recoveryPicker = nil
            } else {
                recoveryPicker =
                    AgenticRuntimeToolPlanRecoveryPicker()
            }

            let envelope =
                try await AgenticRuntimeBridgeRecovery.execute(
                    request,
                    host: host,
                    picker: recoveryPicker
                )

            if options.standardInput {
                try AgenticRuntimeCommandIO.write(
                    envelope
                )

                return
            }

            let text = try AgenticRuntimeCommandIO.text(
                envelope
            )

            guard Clipboard.system.write(
                text
            ) else {
                throw AgenticRuntimeCommandError
                    .clipboardWriteFailed
            }

            print(
                TerminalToolHostReceiptRenderer()
                    .render(
                        envelope,
                        copiedToClipboard: true
                    )
            )
        }
    }
}
