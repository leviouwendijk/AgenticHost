import Agentic
import Foundation
import Primitives

public enum AgenticToolHostJSON {
    public static func decodeRequest(
        _ data: Data
    ) throws -> AgenticToolHostRequest {
        try JSONDecoder().decode(
            AgenticToolHostRequest.self,
            from: data
        )
    }

    /// Legacy structural decoder for trusted/internal callers.
    ///
    /// Model-facing invocation input should use AgenticToolHostInvocationParser
    /// through AgenticToolHost.decodeInvocationRequest. The parser owns the host
    /// wire grammar and model-facing admission; semantic `input` remains JSONValue
    /// until the registered Tool boundary decodes its concrete `T.Input`.
    public static func decodeInvocationRequest(
        _ data: Data,
        registry: ToolRegistry
    ) throws -> AgenticToolHostRequest {
        try AgenticToolHostInvocationParser(
            registry: registry
        ).parse(
            data
        )
    }

    public static func decodeEnvelope(
        _ data: Data
    ) throws -> AgenticToolHostEnvelope {
        try JSONDecoder().decode(
            AgenticToolHostEnvelope.self,
            from: data
        )
    }

    public static func encode(
        _ request: AgenticToolHostRequest,
        prettyPrinted: Bool = false
    ) throws -> Data {
        try encoder(
            prettyPrinted: prettyPrinted
        ).encode(
            request
        )
    }

    public static func encode(
        _ envelope: AgenticToolHostEnvelope,
        prettyPrinted: Bool = false
    ) throws -> Data {
        try encoder(
            prettyPrinted: prettyPrinted
        ).encode(
            envelope
        )
    }

    public static func encodeString(
        _ request: AgenticToolHostRequest,
        prettyPrinted: Bool = false
    ) throws -> String {
        try string(
            from: encode(
                request,
                prettyPrinted: prettyPrinted
            )
        )
    }

    public static func encodeString(
        _ envelope: AgenticToolHostEnvelope,
        prettyPrinted: Bool = false
    ) throws -> String {
        try string(
            from: encode(
                envelope,
                prettyPrinted: prettyPrinted
            )
        )
    }
}

public extension AgenticToolHost {
    /// Parse raw model-facing invocation JSON against this host's exact live registry.
    func decodeInvocationRequest(
        _ data: Data
    ) throws -> AgenticToolHostRequest {
        try AgenticToolHostInvocationParser(
            registry: registry
        ).parse(
            data
        )
    }
}

private extension AgenticToolHostJSON {
    static func encoder(
        prettyPrinted: Bool
    ) -> JSONEncoder {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [
            .sortedKeys
        ]

        if prettyPrinted {
            formatting.insert(
                .prettyPrinted
            )
        }

        encoder.outputFormatting = formatting

        return encoder
    }

    static func string(
        from data: Data
    ) throws -> String {
        guard let value = String(
            data: data,
            encoding: .utf8
        ) else {
            throw AgenticToolHostJSONError.invalidUTF8
        }

        return value
    }
}

public enum AgenticToolHostJSONError:
    Error,
    LocalizedError,
    Sendable
{
    case invalidUTF8
    case invalidInvocationRequest
    case malformedInvocation(JSONDecodingError)
    case invalidInvocation(JSONDiagnostics)

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "Encoded Agentic tool-host JSON was not valid UTF-8."

        case .invalidInvocationRequest:
            return "Expected canonical Agentic host invocation JSON matching the capability manifest: DirectInvocation, non-empty FunctionCall array, or ToolPlan."

        case .malformedInvocation(let error):
            return error.errorDescription
                ?? "Malformed Agentic host invocation JSON."

        case .invalidInvocation(let diagnostics):
            guard !diagnostics.issues.isEmpty else {
                return "Invalid Agentic host invocation."
            }

            let lines = diagnostics.issues.map {
                issue in

                "  \(issue.path.jsonPath)  \(issue.reason)"
            }

            return (
                "Invalid Agentic host invocation (\(diagnostics.issues.count) issue(s)):\n"
                    + lines.joined(separator: "\n")
            )
        }
    }
}
