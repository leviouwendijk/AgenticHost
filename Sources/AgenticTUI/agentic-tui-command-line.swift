import Agentic
import AgenticCommandLine
import AgenticRuntime
import Arguments

/// Full terminal command composition. The headless command root is kept
/// independent of this module and does not depend on terminal dashboards.
public extension Agentic {
    enum TUICommandLine<
        Application: AgenticApplicationProviding
    >: ArgumentCommand {
        public static var name: String { "agentic" }
        public static var defaultChild: Help.Type { Help.self }

        public static var children: [ArgumentCommandType] {
            [
                Help.self,
                AgenticDiagnosticsCommand<Application>.self,
                AgenticToolCommand<Application>.self,
                AgenticRunShellCommand<Application>.self,
                AgenticLogCommand<Application>.self,
                AgenticTUIHostCommand<Application>.self,
                AgenticConversationCommand<Application>.self,
                AgenticWorkCommand<Application>.self,
            ]
        }

        public static func main() async {
            await ArgumentProgram.main(
                command: Self.self,
                errorHandler: { error in
                    AgenticCommandLineIO.writeError(
                        error,
                        commandName: name
                    )
                    return 1
                }
            )
        }

        public enum Help: RunnableArgumentCommand {
            public static var name: String { "help" }

            public static func run(
                _ invocation: ParsedInvocation
            ) async throws {
                _ = invocation
                print(
                    ArgumentHelpRenderer().render(
                        command: try TUICommandLine<Application>.spec()
                    )
                )
            }
        }
    }
}
