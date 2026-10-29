import AgenticRuntime
import Arguments

/// Starts an empty Work dashboard. Sessions are created by selecting an
/// installed Agent from the dashboard; no authored launch entries are needed.
public enum AgenticWorkCommand<
    Application: AgenticApplicationProviding
>: ParsedArgumentCommand {
    public typealias Options = HostOptions

    public static var name: String { "work" }

    public static func run(
        _ options: Options,
        invocation: ParsedInvocation
    ) async throws {
        _ = invocation
        try await AgenticWorkConsole.launch(
            Application.self,
            workspace: options.workspace,
            voiceInput: Application.hostVoiceInputProvider,
            startConversation: false
        )
    }
}
