// AgenticInterfaces/Sources/AgenticInterfacesTestFlows/project-discovery-temp-fixture.swift
// scope: whole file
// change: addition

import Foundation

enum ProjectDiscoveryTempFixture {
    static let packagePath = "Package.swift"
    static let userFormatterPath = "Sources/App/UserFormatter.swift"
    static let dogFormatterPath = "Sources/App/DogFormatter.swift"
    static let unusedPath = "Sources/App/Unused.swift"
    static let userFormatterTestPath = "Tests/AppTests/UserFormatterTests.swift"
    static let envPath = ".env"
    static let agenticStatePath = ".agentic/state.json"

    static func install(
        in workspace: TempProjectWorkspace
    ) throws {
        try workspace.write(
            packageContent,
            to: packagePath
        )

        try workspace.write(
            userFormatterContent,
            to: userFormatterPath
        )

        try workspace.write(
            dogFormatterContent,
            to: dogFormatterPath
        )

        try workspace.write(
            unusedContent,
            to: unusedPath
        )

        try workspace.write(
            userFormatterTestContent,
            to: userFormatterTestPath
        )

        try workspace.write(
            envContent,
            to: envPath
        )

        try workspace.write(
            agenticStateContent,
            to: agenticStatePath
        )
    }

    static let helperLines = [
        "    private func trimString(_ string: String) -> String {",
        "        return string.trimmingCharacters(in: .whitespacesAndNewlines)",
        "    }"
    ]

    static let packageContent = """
    // swift-tools-version: 6.2

    import PackageDescription

    let package = Package(
        name: "FixtureApp",
        products: [
            .library(
                name: "FixtureApp",
                targets: ["FixtureApp"]
            ),
        ],
        targets: [
            .target(
                name: "FixtureApp",
                path: "Sources/App"
            ),
            .testTarget(
                name: "FixtureAppTests",
                dependencies: ["FixtureApp"],
                path: "Tests/AppTests"
            ),
        ]
    )

    """

    static let userFormatterContent = """
    public struct UserFormatter {
        public init() {
        }

        public func displayName(
            name: String,
            city: String
        ) -> String {
            let trimmedName = name
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            let trimmedCity = city
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

            return "\\(trimmedName) from \\(trimmedCity)"
        }
    }

    """

    static let dogFormatterContent = """
    public struct DogFormatter {
        public init() {
        }

        public func displayDog(
            name: String,
            breed: String
        ) -> String {
            let trimmedName = name
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            let trimmedBreed = breed
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

            return "\\(trimmedName) is a \\(trimmedBreed)"
        }
    }

    """

    static let unusedContent = """
    public struct Unused {
        public init() {
        }

        public func render() -> String {
            "unused"
        }
    }

    """

    static let userFormatterTestContent = """
    import FixtureApp

    struct UserFormatterTests {
        func testDisplayName() {
            _ = UserFormatter().displayName(
                name: " Levi ",
                city: " Alkmaar "
            )
        }
    }

    """

    static let envContent = """
    SECRET_TOKEN=do-not-read-this-fixture-secret

    """

    static let agenticStateContent = """
    {
        "note": "this fixture file should not be read or mutated by the discovery flow"
    }

    """
}
