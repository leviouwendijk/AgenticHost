import Foundation

public struct ScriptedDogFormatter {
    public init() {}

    public func renderDog(
        name: String,
        breed: String,
        age: Int
    ) -> String {
        let trimmedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let trimmedBreed = breed.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        return "dog=\(trimmedName); breed=\(trimmedBreed); age=\(age)"
    }

    public func renderClient(
        client: String,
        topic: String,
        hour: Int
    ) -> String {
        let trimmedClient = client.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let trimmedTopic = topic.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        return "client=\(trimmedClient); topic=\(trimmedTopic); hour=\(hour)"
    }

    public func renderLocation(
        street: String,
        city: String,
        zip: String
    ) -> String {
        let trimmedStreet = street.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let trimmedCity = city.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        return "street=\(trimmedStreet); city=\(trimmedCity); zip=\(zip)"
    }
}
