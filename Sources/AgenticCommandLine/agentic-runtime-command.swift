import AgenticRuntime
import Arguments

public enum AgenticRuntimeCommand<
    Application: AgenticApplicationProviding
>:
    ArgumentCommand
{
    public static var name: String {
        "agentic"
    }

    public static var defaultChild: Help.Type {
        Help.self
    }

    public static var children: [ArgumentCommandType] {
        [
            Help.self,
            AgenticRuntimeToolCommand<Application>.self,
            AgenticRuntimeHostCommand<Application>.self,
            AgenticRuntimeConversationCommand<Application>.self,
        ]
    }

    public static func main() async {
        await ArgumentProgram.main(
            command: Self.self,
            errorHandler: { error in
                AgenticRuntimeCommandIO.writeError(
                    error,
                    commandName: name
                )

                return 1
            }
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
                    command: try AgenticRuntimeCommand<Application>.spec()
                )
            )
        }
    }
}
