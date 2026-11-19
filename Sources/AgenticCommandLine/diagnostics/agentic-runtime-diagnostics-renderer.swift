import Agentic
import AgenticRuntime
import AgenticSensitivity
import Foundation

public enum AgenticRuntimeDiagnosticsRenderer {
    /// The owner's context: how much there is and what every run receives.
    public static func render(
        _ context: ContextEntrySummary
    ) -> String {
        var lines = [
            "Context",
            "directory  \(context.directory)",
            "entries  \(context.entries)",
            context.always.isEmpty
                ? "always  none"
                : "always  \(context.always.count) (≈\(context.alwaysTokens) tokens): \(context.always.joined(separator: ", "))",
        ]
        if !context.problems.isEmpty {
            lines.append("problems")
            lines += context.problems.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    /// The handle vault as `domains/sensitivity.frame` configures it.
    public static func render(
        privacy configuration: Privacy.Configuration,
        file: String,
        exists: Bool,
        problem: String?
    ) -> String {
        let expiry: String
        switch configuration.expiry {
        case .unreferenced: expiry = "unreferenced"
        case .onSessionClose: expiry = "on session close"
        case .after(let days): expiry = "after \(days) days"
        }
        var lines = [
            "Sensitivity",
            "file  \(file)\(exists ? "" : " (absent: defaults)")",
            "vault  \(configuration.store.rawValue), expires \(expiry)" + (configuration.expiry == .unreferenced ? " (references in \(configuration.references.rawValue)\(configuration.roots.isEmpty ? "" : " + \(configuration.roots.count) root\(configuration.roots.count == 1 ? "" : "s")"))" : ""),
            "handles at  \(configuration.shield.handleAt), soft at \(configuration.shield.softAt)",
            "never replaced  \(configuration.shield.never.count) value\(configuration.shield.never.count == 1 ? "" : "s")",
        ]
        if let problem {
            lines.append("problems")
            lines.append("- \(problem) (defaults in use)")
        }
        return lines.joined(separator: "\n")
    }

    public static func render(
        _ diagnostics: RuntimeDiagnostics,
        verbose: Bool = false
    ) -> String {
        var lines: [String] = [
            "Agentic runtime",
            "application  \(diagnostics.application.rawValue)",
            "",
            "Capabilities",
            header,
            row(
                "catalog",
                diagnostics.catalog
            ),
            row(
                "installed",
                diagnostics.installed
            ),
            row(
                "model-callable",
                diagnostics.modelCallable
            ),
            "",
            "Runtime",
            "registered tools  \(diagnostics.registeredTools)",
            "model-facing tools  \(diagnostics.modelFacingTools)",
            "launches  \(diagnostics.launches.count)",
            "gateways available  \(diagnostics.availableGateways.count)",
            "gateways unavailable  \(diagnostics.unavailableGateways.count)",
            "profiles  \(diagnostics.profiles.count)",
        ]

        if !diagnostics.agents.isEmpty {
            lines.append("")
            lines.append("Agents")

            for agent in diagnostics.agents {
                lines.append(
                    "\(agent.identifier.rawValue)  available \(compact(agent.available))  visible \(compact(agent.visible))"
                )
            }
        }

        if !diagnostics.warnings.isEmpty {
            lines.append("")
            lines.append("Warnings")

            for warning in diagnostics.warnings {
                lines.append(
                    "- \(warning.rawValue)"
                )
            }
        }

        if verbose {
            appendVerbose(
                label: "catalog",
                capabilities: diagnostics.catalog,
                to: &lines
            )
            appendVerbose(
                label: "installed",
                capabilities: diagnostics.installed,
                to: &lines
            )
            appendVerbose(
                label: "model-callable",
                capabilities: diagnostics.modelCallable,
                to: &lines
            )
        }

        return lines.joined(
            separator: "\n"
        )
    }

    public static func render(
        _ diagnostics: AgentRuntimeDiagnostics,
        verbose: Bool = false
    ) -> String {
        var lines: [String] = [
            "Agent \(diagnostics.identifier.rawValue)",
            "",
            "Capabilities",
            header,
            row(
                "requested available",
                diagnostics.requestedAvailable
            ),
            row(
                "installed",
                diagnostics.installed
            ),
            row(
                "available",
                diagnostics.available
            ),
            row(
                "requested visible",
                diagnostics.requestedVisible
            ),
            row(
                "visible",
                diagnostics.visible
            ),
        ]

        if verbose {
            appendVerbose(
                label: "requested available",
                capabilities: diagnostics.requestedAvailable,
                to: &lines
            )
            appendVerbose(
                label: "installed",
                capabilities: diagnostics.installed,
                to: &lines
            )
            appendVerbose(
                label: "available",
                capabilities: diagnostics.available,
                to: &lines
            )
            appendVerbose(
                label: "requested visible",
                capabilities: diagnostics.requestedVisible,
                to: &lines
            )
            appendVerbose(
                label: "visible",
                capabilities: diagnostics.visible,
                to: &lines
            )
        }

        return lines.joined(
            separator: "\n"
        )
    }

    public static func json<Value: Encodable>(
        _ value: Value
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]

        let data = try encoder.encode(
            value
        )

        return String(
            decoding: data,
            as: UTF8.self
        )
    }

    private static let header =
        "                     tools  programs  inferences  agents"

    private static func row(
        _ label: String,
        _ capabilities: AgentCapabilitySet
    ) -> String {
        let padded = label.padding(
            toLength: 20,
            withPad: " ",
            startingAt: 0
        )

        return "\(padded) \(capabilities.tools.count)      \(capabilities.programs.count)         \(capabilities.inferences.count)           \(capabilities.agents.count)"
    }

    private static func compact(
        _ capabilities: AgentCapabilitySet
    ) -> String {
        "T\(capabilities.tools.count) P\(capabilities.programs.count) I\(capabilities.inferences.count) A\(capabilities.agents.count)"
    }

    private static func appendVerbose(
        label: String,
        capabilities: AgentCapabilitySet,
        to lines: inout [String]
    ) {
        lines.append("")
        lines.append("\(label) identifiers")

        append(
            "tools",
            capabilities.tools.map(
                \.rawValue
            ),
            to: &lines
        )
        append(
            "programs",
            capabilities.programs.map(
                \.rawValue
            ),
            to: &lines
        )
        append(
            "inferences",
            capabilities.inferences.map(
                \.rawValue
            ),
            to: &lines
        )
        append(
            "agents",
            capabilities.agents.map(
                \.rawValue
            ),
            to: &lines
        )
    }

    private static func append(
        _ label: String,
        _ identifiers: [String],
        to lines: inout [String]
    ) {
        lines.append("\(label):")

        if identifiers.isEmpty {
            lines.append("  -")
            return
        }

        for identifier in identifiers {
            lines.append(
                "  \(identifier)"
            )
        }
    }
}
