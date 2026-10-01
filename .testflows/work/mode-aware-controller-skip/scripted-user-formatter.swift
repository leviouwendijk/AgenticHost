import Foundation

public struct ScriptedUserFormatter {
    public init() {}

    public func renderUser(
        name: String,
        city: String,
        score: Int
    ) -> String {
        let trimmedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let trimmedCity = city.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        return "user=\(trimmedName); city=\(trimmedCity); score=\(score)"
    }

    public func renderStatus(
        label: String,
        owner: String
    ) -> String {
        return "status=\(label); owner=\(owner)"
    }
}
