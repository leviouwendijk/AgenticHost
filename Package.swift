// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "AgenticHost",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "AgenticHost",
            targets: [
                "AgenticHost",
            ]
        ),
        .library(
            name: "AgenticCommandLine",
            targets: [
                "AgenticCommandLine",
            ]
        ),
        .executable(
            name: "artest",
            targets: [
                "AgenticHostTestFlows",
            ]
        ),
        .executable(
            name: "ahinttest",
            targets: [
                "AgenticHostIntegrationTestFlows",
            ]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/leviouwendijk/AgenticRuntime.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/Agentic.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/AgenticExecution.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/AgenticWorkspace.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/AgenticModels.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/AgenticUsage.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/AgenticInterfaces.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/AgenticTools.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/Primitives.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/Arguments.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/Clipboard.git",
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
            url: "https://github.com/leviouwendijk/AgenticIO.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/AgenticProviders.git",
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
            url: "https://github.com/leviouwendijk/SchemaMacros.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/TestFlows.git",
            branch: "master"
        ),
    ],
    targets: [
        .target(
            name: "AgenticHost",
            dependencies: [
                .product(
                    name: "AgenticRuntime",
                    package: "AgenticRuntime"
                ),
                .product(
                    name: "Agentic",
                    package: "Agentic"
                ),
                .product(
                    name: "AgenticExecution",
                    package: "AgenticExecution"
                ),
                .product(
                    name: "AgenticInterfaces",
                    package: "AgenticInterfaces"
                ),
                .product(
                    name: "AgenticModels",
                    package: "AgenticModels"
                ),
                .product(
                    name: "AgenticUsage",
                    package: "AgenticUsage"
                ),
                .product(
                    name: "AgenticWorkspace",
                    package: "AgenticWorkspace"
                ),
            ]
        ),
        .target(
            name: "AgenticCommandLine",
            dependencies: [
                "AgenticHost",
                .product(
                    name: "AgenticRuntime",
                    package: "AgenticRuntime"
                ),
                .product(
                    name: "Agentic",
                    package: "Agentic"
                ),
                .product(
                    name: "AgenticExecution",
                    package: "AgenticExecution"
                ),
                .product(
                    name: "AgenticWorkspace",
                    package: "AgenticWorkspace"
                ),
                .product(
                    name: "AgenticModels",
                    package: "AgenticModels"
                ),
                .product(
                    name: "AgenticUsage",
                    package: "AgenticUsage"
                ),
                .product(
                    name: "AgenticInterfaces",
                    package: "AgenticInterfaces"
                ),
                .product(
                    name: "AgenticTools",
                    package: "AgenticTools"
                ),
                .product(
                    name: "Primitives",
                    package: "Primitives"
                ),
                .product(
                    name: "Arguments",
                    package: "Arguments"
                ),
                .product(
                    name: "Clipboard",
                    package: "Clipboard"
                ),
                .product(
                    name: "DSL",
                    package: "DSL"
                ),
                .product(
                    name: "ErrorsDSL",
                    package: "Errors"
                ),
                .product(
                    name: "Terminal",
                    package: "Terminal"
                ),
            ]
        ),
        .executableTarget(
            name: "AgenticHostTestFlows",
            dependencies: [
                "AgenticHost",
                "AgenticCommandLine",
                .product(
                    name: "AgenticRuntime",
                    package: "AgenticRuntime"
                ),
                .product(
                    name: "Agentic",
                    package: "Agentic"
                ),
                .product(
                    name: "AgenticInterfaces",
                    package: "AgenticInterfaces"
                ),
                .product(
                    name: "AgenticExecution",
                    package: "AgenticExecution"
                ),
                .product(
                    name: "AgenticTools",
                    package: "AgenticTools"
                ),
                .product(
                    name: "AgenticWorkspace",
                    package: "AgenticWorkspace"
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
                    name: "SchemaMacros",
                    package: "SchemaMacros"
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
                "AgenticHost",
                "AgenticCommandLine",
                .product(
                    name: "AgenticRuntime",
                    package: "AgenticRuntime"
                ),
                .product(
                    name: "Agentic",
                    package: "Agentic"
                ),
                .product(
                    name: "AgenticExecution",
                    package: "AgenticExecution"
                ),
                .product(
                    name: "AgenticWorkspace",
                    package: "AgenticWorkspace"
                ),
                .product(
                    name: "AgenticModels",
                    package: "AgenticModels"
                ),
                .product(
                    name: "AgenticIO",
                    package: "AgenticIO"
                ),
                .product(
                    name: "AgenticTools",
                    package: "AgenticTools"
                ),
                .product(
                    name: "AgenticInterfaces",
                    package: "AgenticInterfaces"
                ),
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
                    name: "SchemaMacros",
                    package: "SchemaMacros"
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
