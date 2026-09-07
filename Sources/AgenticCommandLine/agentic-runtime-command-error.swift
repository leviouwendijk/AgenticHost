import Foundation

public enum AgenticRuntimeCommandError:
    Error,
    Sendable,
    LocalizedError
{
    case missingStandardInput
    case missingClipboardInput
    case clipboardWriteFailed
    case blankToolName

    public var errorDescription: String? {
        switch self {
        case .missingStandardInput:
            return "Missing Agentic tool-host invocation JSON on standard input."

        case .missingClipboardInput:
            return "Missing Agentic tool-host invocation JSON on the system clipboard."

        case .clipboardWriteFailed:
            return "Failed to write output to the system clipboard."

        case .blankToolName:
            return "Tool name cannot be blank."
        }
    }
}
