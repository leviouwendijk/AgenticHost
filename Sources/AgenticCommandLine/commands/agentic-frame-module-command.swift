import AgenticRuntime
import Arguments

/// Writes the `Agentic` module file, and the modules the application's
/// domains declare, where editors find them, so `settings.frame` and
/// `domains/*.frame` get completion and checking. Run again after an
/// upgrade that changes them.
public enum AgenticFrameModuleCommand<
    Application: AgenticApplicationProviding
>: RunnableArgumentCommand {
    public static var name: String {
        "frame-module"
    }

    public static func run(
        _ invocation: ParsedInvocation
    ) async throws {
        _ = invocation

        for file in try FrameAgenticModule.install(for: Application.self) {
            print(file.path)
        }
    }
}
