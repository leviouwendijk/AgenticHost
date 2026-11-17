import AgenticRuntime
import Arguments

/// Writes the `Agentic` module file where editors find it, so
/// `settings.frame` gets completion and checking. Run again after an
/// upgrade that changes the settings.
public enum AgenticFrameModuleCommand: RunnableArgumentCommand {
    public static var name: String {
        "frame-module"
    }

    public static func run(
        _ invocation: ParsedInvocation
    ) async throws {
        _ = invocation

        print(
            try AgenticFrame.install().path
        )
    }
}
