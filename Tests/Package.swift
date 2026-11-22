// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "AgenticHostTests",
    platforms: [
        .macOS(.v13),
    ],
    products: [

        // tests
        .executable(
            name: "t_ah_main",
            targets: [
                "AgenticHostTestFlows",
            ]
        ),
        .executable(
            name: "t_ah_integration",
            targets: [
                "AgenticHostIntegrationTestFlows",
            ]
        ),
        .executable(
            name: "t_ah_structured",
            targets: ["AgenticHostStructuredTesting"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/leviouwendijk/Agentic.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/AgenticRuntime.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/Workspace.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/Writers.git",
            branch: "master"
        ),
        .package(url: "https://github.com/leviouwendijk/Sensitivity.git", branch: "master"),
        .package(
            url: "https://github.com/leviouwendijk/AgenticInterfaces.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/AgenticIO.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/AgenticProviders.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/Primitives.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/DSL.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/Errors.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/Terminal.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/Reporting.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/AWSConnector.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/Difference.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/Schema.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/Macros.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/TestFlows.git",
            branch: "master"
        ),
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "AgenticHostStructuredTesting",
            dependencies: [
                .product(name: "AgenticCommandLine", package: "AgenticHost"),
                .product(name: "AgenticTUI", package: "AgenticHost"),
                .product(name: "Agentic", package: "Agentic"),
                .product(name: "AgenticInterfaces", package: "AgenticInterfaces"),
                .product(name: "AgenticPresentation", package: "AgenticInterfaces"),
                .product(name: "AgenticRuntime", package: "AgenticRuntime"),
                .product(name: "AgenticConfiguration", package: "Agentic"),
                .product(name: "AgenticStandard", package: "Agentic"),
                .product(name: "Primitives", package: "Primitives"),
                .product(name: "Reporting", package: "Reporting"),
            ]
        ),
        .executableTarget(
            name: "AgenticHostTestFlows",
            dependencies: [
                .product(
                    name: "AgenticContextWindow",
                    package: "Agentic"
                ),
                .product(
                    name: "AgenticSessions",
                    package: "Agentic"
                ),
                .product(name: "AgenticHost", package: "AgenticHost"),
                .product(name: "AgenticCommandLine", package: "AgenticHost"),
                .product(name: "AgenticTUI", package: "AgenticHost"),
                .product(name: "AgenticSensitivity", package: "Agentic"),
                .product(name: "Sensitivity", package: "Sensitivity"),
                .product(
                    name: "Writers",
                    package: "Writers"
                ),
                .product(
                    name: "Agentic",
                    package: "Agentic"
                ),
                .product(
                    name: "AgenticRuntime",
                    package: "AgenticRuntime"
                ),
                .product(name: "AgenticConfiguration", package: "Agentic"),
                .product(
                    name: "AgenticInterfaces",
                    package: "AgenticInterfaces"
                ),
                .product(name: "AgenticPresentation", package: "AgenticInterfaces"),
                .product(
                    name: "AgenticStandard",
                    package: "Agentic"
                ),
                .product(
                    name: "Workspace",
                    package: "Workspace"
                ),
                .product(
                    name: "AgenticApple",
                    package: "AgenticProviders"
                ),
                .product(
                    name: "AgenticOllama",
                    package: "AgenticProviders"
                ),
                .product(
                    name: "Primitives",
                    package: "Primitives"
                ),
                .product(
                    name: "Schema",
                    package: "Schema"
                ),
                .product(
                    name: "Macros",
                    package: "Macros"
                ),
                .product(
                    name: "AgenticIO",
                    package: "AgenticIO"
                ),
                .product(
                    name: "DSL",
                    package: "DSL"
                ),
                .product(
                    name: "Errors",
                    package: "Errors"
                ),
                .product(
                    name: "Difference",
                    package: "Difference"
                ),
                .product(
                    name: "Terminal",
                    package: "Terminal"
                ),
                .product(
                    name: "TestFlows",
                    package: "TestFlows"
                ),
            ]
        ),
        .executableTarget(
            name: "AgenticHostIntegrationTestFlows",
            dependencies: [
                .product(name: "AgenticHost", package: "AgenticHost"),
                .product(name: "AgenticCommandLine", package: "AgenticHost"),
                .product(
                    name: "Agentic",
                    package: "Agentic"
                ),
                .product(
                    name: "AgenticModels",
                    package: "Agentic"
                ),
                .product(
                    name: "AgenticRuntime",
                    package: "AgenticRuntime"
                ),
                .product(name: "AgenticConfiguration", package: "Agentic"),
                .product(
                    name: "Workspace",
                    package: "Workspace"
                ),
                .product(
                    name: "AgenticIO",
                    package: "AgenticIO"
                ),
                .product(
                    name: "AgenticStandard",
                    package: "Agentic"
                ),
                .product(
                    name: "AgenticInterfaces",
                    package: "AgenticInterfaces"
                ),
                .product(name: "AgenticPresentation", package: "AgenticInterfaces"),
                .product(
                    name: "AgenticApple",
                    package: "AgenticProviders"
                ),
                .product(
                    name: "AgenticAWS",
                    package: "AgenticProviders"
                ),
                .product(
                    name: "AWSConnector",
                    package: "AWSConnector"
                ),
                .product(
                    name: "Primitives",
                    package: "Primitives"
                ),
                .product(
                    name: "Schema",
                    package: "Schema"
                ),
                .product(
                    name: "Macros",
                    package: "Macros"
                ),
                .product(
                    name: "Difference",
                    package: "Difference"
                ),
                .product(
                    name: "Terminal",
                    package: "Terminal"
                ),
                .product(
                    name: "TestFlows",
                    package: "TestFlows"
                ),
            ]
        ),
    ],
    swiftLanguageModes: [
        .v6,
    ]
)

for target in package.targets {
    switch target.type {
    case .regular, .executable, .test, .macro:
        var settings = target.swiftSettings ?? []

        settings.append(
            .treatAllWarnings(as: .error)
        )

        settings.append(
            .unsafeFlags(
                [
                    "-continue-building-after-errors"
                ]
            )
        )

        target.swiftSettings = settings

    case .plugin, .system, .binary:
        break

    @unknown default:
        break
    }
}
