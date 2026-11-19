import Agentic
import AgenticHost
import AgenticRuntime
import IO
import AgenticConfiguration
import AgenticSensitivity
import Arguments
import Foundation

public enum AgenticDiagnosticsCommand<
    Application: AgenticApplicationProviding
>:
    ParsedArgumentCommand
{
    public typealias Options =
        AgenticRuntimeDiagnosticsOptions

    public static var name: String {
        "diagnostics"
    }

    public static func run(
        _ options: Options,
        invocation: ParsedInvocation
    ) async throws {
        _ = invocation

        let runtime = try await AgenticRuntime.resolve(
            Application.self
        )

        if let agent = options.agent {
            let diagnostics = try runtime.diagnostics(
                for: agent
            )

            if options.json {
                print(
                    try AgenticRuntimeDiagnosticsRenderer.json(
                        diagnostics
                    )
                )
            } else {
                print(
                    AgenticRuntimeDiagnosticsRenderer.render(
                        diagnostics,
                        verbose: options.verbose
                    )
                )
            }

            return
        }

        let diagnostics = try runtime.diagnostics()
        let context = try AgenticSessionServices.resolve(
            Application.self,
            sessionID: nil
        ).contextSummary

        if options.json {
            print(
                try AgenticRuntimeDiagnosticsRenderer.json(
                    diagnostics
                )
            )
        } else {
            print(
                AgenticRuntimeDiagnosticsRenderer.render(
                    diagnostics,
                    verbose: options.verbose
                )
            )
            if let context {
                print("")
                print(AgenticRuntimeDiagnosticsRenderer.render(context))
            }
            let home = AgentHomeLocator().resolveHome()
            let file = home.layout.domainfile(Privacy.Configuration.fileName)
            let privacy = Privacy.Configuration.load(home: home)
            print("")
            print(
                AgenticRuntimeDiagnosticsRenderer.render(
                    privacy: privacy.configuration,
                    file: file.path,
                    exists: FileSystem.default.exists(file),
                    problem: privacy.problem
                )
            )
        }
    }
}
