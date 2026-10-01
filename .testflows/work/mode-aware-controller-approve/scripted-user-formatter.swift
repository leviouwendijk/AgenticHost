import Foundation

public struct ScriptedUserFormatter {
    public init() {}
    internal func trimString(_ string: String) -> String {
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func renderUser(
        name: String,
        city: String,
        score: Int
    ) -> String {
        let trimmedName = trimString(name)
        let trimmedCity = trimString(city)

        return "user=\(trimmedName); city=\(trimmedCity); score=\(score)"
    }

    public func renderStatus(
        label: String,
        owner: String
    ) -> String {
        return "status=\(label); owner=\(owner)"
    }
}
