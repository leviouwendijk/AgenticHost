import Agentic
import AgenticRuntime
import Foundation

public enum AgenticRuntimeDiagnosticsRenderer {
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
