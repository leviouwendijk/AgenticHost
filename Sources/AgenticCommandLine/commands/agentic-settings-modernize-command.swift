import AgenticConfiguration
import AgenticRuntime
import Arguments

/// Archives the home's `settings.frame` to `archive/` and writes the
/// current template in its place. Nothing replaces the file on its own;
/// the header notes when its declared schema is behind.
public enum AgenticSettingsModernizeCommand<
    Application: AgenticApplicationProviding
>: RunnableArgumentCommand {
    public static var name: String {
        "settings-modernize"
    }

    public static func run(
        _ invocation: ParsedInvocation
    ) async throws {
        _ = invocation

        let home = AgentHomeLocator().resolveHome()
        if let archive = try home.modernizeSettingsFile() {
            print("archived \(archive.path)")
        }
        print(home.layout.settingsfile.path)
    }
}
