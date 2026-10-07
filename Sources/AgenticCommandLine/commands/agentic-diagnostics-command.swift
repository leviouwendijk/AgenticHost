import Agentic
import AgenticRuntime
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
    }
}
