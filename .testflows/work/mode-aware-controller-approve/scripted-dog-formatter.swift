import Foundation

public struct ScriptedDogFormatter {
    public init() {}
    internal func trimString(_ string: String) -> String {
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func renderDog(
        name: String,
        breed: String,
        age: Int
    ) -> String {
        let trimmedName = trimString(name)
        let trimmedBreed = trimString(breed)

        return "dog=\(trimmedName); breed=\(trimmedBreed); age=\(age)"
    }

    public func renderClient(
        client: String,
        topic: String,
        hour: Int
    ) -> String {
        let trimmedClient = trimString(client)
        let trimmedTopic = trimString(topic)

        return "client=\(trimmedClient); topic=\(trimmedTopic); hour=\(hour)"
    }

    public func renderLocation(
        street: String,
        city: String,
        zip: String
    ) -> String {
        let trimmedStreet = trimString(street)
        let trimmedCity = trimString(city)

        return "street=\(trimmedStreet); city=\(trimmedCity); zip=\(zip)"
    }
}
