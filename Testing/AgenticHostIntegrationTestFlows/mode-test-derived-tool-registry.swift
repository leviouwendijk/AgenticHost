import Agentic
import AgenticIO
import AgenticRuntime

/// Derive the test's executable Tool universe from the authored SystemIO Domain.
enum ModeTestDerivedToolRegistry {
    static func make() throws -> ToolRegistry {
        let application = Agentic.application("fixture.mode.system_io") {
            install(SystemIO.self)
        }
        return try InstalledCapabilities(application: application).tools
    }
}
