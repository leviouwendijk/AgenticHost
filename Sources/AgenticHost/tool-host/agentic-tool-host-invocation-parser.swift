import Agentic
import Foundation
import Primitives

/// Parses untrusted invocation JSON through the live registered tool universe.
///
/// The raw JSON shape is classified and diagnosed before Codable construction.
/// The host grammar already carries semantic tool input under `input`, so parsing
/// preserves that JSONValue rather than reinterpreting it as Agentic's raw
/// provider/model `{ arguments, execution? }` envelope. Concrete `T.Input`
/// decoding remains owned by the registered Tool boundary during preflight/call.
public struct AgenticToolHostInvocationParser:
    Sendable
{
    public let registry: ToolRegistry

    public init(
        registry: ToolRegistry
    ) {
        self.registry = registry
    }

    public func parse(
        _ data: Data
    ) throws -> AgenticToolHostRequest {
        let value: JSONValue

        do {
            value = try JSONCoding.default.decode(
                JSONValue.self,
                from: data
            )
        } catch {
            throw AgenticToolHostJSONError.malformedInvocation(
                error
            )
        }

        let diagnostics = AgenticToolHostInvocationContract.diagnostics(
            value,
            capabilities: registry.inspect().tools
        )

        guard diagnostics.isEmpty else {
            throw AgenticToolHostJSONError.invalidInvocation(
                diagnostics
            )
        }

        switch value {
        case .array:
            let calls = try JSONCoding.default.decode(
                [AgenticToolHostCall].self,
                from: data
            )

            return AgenticToolHostRequest(
                action: .invoke,
                calls: calls.map(\.agentToolCall)
            )

        case .object(let object):
            if object["root"] != nil {
                let plan = try JSONCoding.default.decode(
                    AgenticToolHostPlan.self,
                    from: data
                )

                return AgenticToolHostRequest(
                    action: .invoke,
                    plan:
                        try plan.agentToolPlan(
                            registry: registry
                        )
                )
            }

            let invocation = try JSONCoding.default.decode(
                AgenticToolHostDirectInvocation.self,
                from: data
            )

            return AgenticToolHostRequest(
                action: .invoke,
                call: invocation.call,
                execution: invocation.execution
            )

        default:
            throw AgenticToolHostJSONError.invalidInvocation(
                JSONDiagnostics(
                    [
                        JSONIssue(
                            kind: .typeMismatch,
                            path: JSONCodingPath(),
                            reason: "Expected a direct invocation object, non-empty FunctionCall array, or ToolPlan object."
                        ),
                    ]
                )
            )
        }
    }
}
