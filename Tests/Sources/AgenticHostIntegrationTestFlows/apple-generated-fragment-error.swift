import Foundation

enum AppleGeneratedFragmentError: Error, Sendable, LocalizedError {
    case missingJSONObject(String)
    case emptyField(String)
    case fieldTooLong(field: String, count: Int, maximum: Int)

    var errorDescription: String? {
        switch self {
        case .missingJSONObject(let text):
            return "Apple generated output did not contain a JSON object: \(text)"

        case .emptyField(let field):
            return "Apple generated fragment field '\(field)' was empty."

        case .fieldTooLong(let field, let count, let maximum):
            return "Apple generated fragment field '\(field)' was too long: \(count)/\(maximum)."
        }
    }
}
