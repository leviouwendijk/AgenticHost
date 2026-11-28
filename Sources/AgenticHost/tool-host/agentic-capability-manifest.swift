import Agentic
import Foundation
import Primitives
import Schema

/// Runtime manifest derived from the exact ToolRegistry supplied to this host.
public struct AgenticCapabilityManifest:
    Sendable
{
    public let workspaceRoot: String?
    public let sessionID: String?
    public let capabilities: [ToolRegistryInspectionEntry]
    public let invocationSchema: JSONSchema
    public let canonicalPlanExample: ToolPlan?

    public init(
        workspaceRoot: String? = nil,
        sessionID: String? = nil,
        capabilities: [ToolRegistryInspectionEntry]
    ) {
        self.workspaceRoot = workspaceRoot
        self.sessionID = sessionID
        self.capabilities = capabilities
        self.invocationSchema =
            AgenticToolHostInvocationContract.schema(
                registryInspection: capabilities
            )
        self.canonicalPlanExample =
            AgenticToolHostInvocationContract.canonicalPlanExample(
                registryInspection: capabilities
            )
    }
}

public extension AgenticToolHost {
    func capabilityManifest()
        -> AgenticCapabilityManifest
    {
        .init(
            workspaceRoot:
                workspace?
                    .absoluteURL
                    .path,
            sessionID: sessionID,
            capabilities:
                registry.inspect().tools
        )
    }

    func capabilityManifestText() throws
        -> String
    {
        try AgenticCapabilityManifestRenderer.render(
            capabilityManifest()
        )
    }
}

public enum AgenticCapabilityManifestRenderer {
    public static func render(
        _ manifest: AgenticCapabilityManifest
    ) throws -> String {
        var lines = [
            "AGENTIC CAPABILITY MANIFEST",
            "",
            "Workspace authority root:",
            "    \(manifest.workspaceRoot ?? "<none>")",
            "Session:",
            "    \(manifest.sessionID ?? "<none>")",
            "",
            "Available tools (\(manifest.capabilities.count)):",
        ]

        for capability in manifest.capabilities {
            lines.append("")
            lines.append(
                capability.identifier.rawValue
            )
            lines.append(
                "    risk: \(capability.risk.rawValue)"
            )
            lines.append(
                "    model_exposure: \(capability.isModelFacing ? "model_facing" : "host_only")"
            )
            lines.append(
                "    semantic_input_schema: \(capability.semanticInputSchema == nil ? "unavailable" : "available")"
            )
            lines.append(
                "    description:"
            )
            lines.append(
                contentsOf: indentedLines(
                    capability.description,
                    spaces: 8
                )
            )
        }

        lines.append("")
        lines.append(
            "Invocation schema:"
        )
        lines.append(
            "    Submit exactly one of these JSON shapes directly to agentic host bridge."
        )
        lines.append(
            contentsOf: try renderedJSONLines(
                manifest.invocationSchema.jsonvalue,
                spaces: 4
            )
        )

        lines.append("")
        lines.append(
            "Canonical ToolPlan example:"
        )

        if let example = manifest.canonicalPlanExample {
            lines.append(
                contentsOf: try renderedEncodableLines(
                    example,
                    spaces: 4
                )
            )
        } else {
            lines.append(
                "    <no registered tools>"
            )
        }

        lines.append("")
        lines.append(
            "Protocol guidance:"
        )
        lines.append(
            contentsOf: protocolLines()
        )

        return lines.joined(
            separator: "\n"
        )
    }
}

private extension AgenticCapabilityManifestRenderer {
    static func protocolLines() -> [String] {
        [
            "    - Treat the Invocation schema as the authoritative local host-call grammar and the registered tool variants inside it as the authoritative tool surface for this session.",
            "    - Submit a DirectInvocation, non-empty FunctionCall array, or ToolPlan directly. Do not invent action/request/tool_call/tool_calls wrappers that are not present in the Invocation schema.",
            "    - model_exposure is explicit. model_facing tools have a captured typed parser and semantic_input_schema and appear in the Invocation schema; host_only tools remain registered for trusted host/runtime use but are not model-invokable.",
            "    - For multi-step or dependent work, prefer one ToolPlan with sequence, batch, and outcome branches rather than issuing unrelated invocation envelopes.",
            "    - Use sequence for ordered success-gated dependencies; it stops after the first non-success and skips remaining siblings.",
            "    - Use onSuccess, onFailure, and onDenied when subsequent work differs by call outcome.",
            "    - After pushing an upstream Swift package, when a later step builds or tests a dependent package and swift_tool_package_update is declared, run swift_tool_package_update in that dependent package first so it consumes the new upstream revision.",
            "    - execution.workspace.subpath is ordinary optional invocation metadata for every model-facing tool. It selects a working location beneath the workspace authority root; Workspace decides whether the target is permitted and it does not narrow or rebase authority.",
            "    - Normal invocation already performs governed preflight, policy evaluation, and approval handling before execution; do not issue a separate preflight by default.",
            "    - Use explicit preflight only when a tool call should be inspected or reviewed without executing it.",
            "    - Prefer a declared typed Agentic tool over an equivalent shell or process operation.",
            "    - Treat Agentic invocation and ToolPlan results as authoritative execution state.",
        ]
    }

    static func renderedJSONLines(
        _ value: JSONValue,
        spaces: Int
    ) throws -> [String] {
        let data = try encoder().encode(
            value
        )

        return indentedLines(
            String(
                decoding: data,
                as: UTF8.self
            ),
            spaces: spaces
        )
    }

    static func renderedEncodableLines<Value: Encodable>(
        _ value: Value,
        spaces: Int
    ) throws -> [String] {
        let data = try encoder().encode(
            value
        )

        return indentedLines(
            String(
                decoding: data,
                as: UTF8.self
            ),
            spaces: spaces
        )
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]
        return encoder
    }

    static func indentedLines(
        _ text: String,
        spaces: Int
    ) -> [String] {
        let prefix = String(
            repeating: " ",
            count: spaces
        )

        return text
            .split(
                separator: "\n",
                omittingEmptySubsequences: false
            )
            .map {
                prefix + String($0)
            }
    }
}
