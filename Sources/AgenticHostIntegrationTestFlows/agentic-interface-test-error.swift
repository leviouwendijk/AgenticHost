import Foundation

enum AgenticInterfaceTestError: Error, Sendable, LocalizedError {
    case unknownTestCase(String, available: [String])
    case missingValue(String)
    case unknownArgument(String)
    case invalidInteger(argument: String, value: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unknownTestCase(let id, let available):
            return "Unknown interface test case '\(id)'. Available: \(available.sorted().joined(separator: ", "))."

        case .missingValue(let argument):
            return "Missing value after \(argument)."

        case .unknownArgument(let argument):
            return "Unknown argument '\(argument)'."

        case .invalidInteger(let argument, let value):
            return "Invalid integer for \(argument): \(value)."

        case .cancelled:
            return "No interface test case was selected."
        }
    }
}

func requireNext(
    _ iterator: inout Array<String>.Iterator,
    after argument: String
) throws -> String {
    guard let value = iterator.next() else {
        throw AgenticInterfaceTestError.missingValue(
            argument
        )
    }

    return value
}
