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
        .library(
            name: "AgenticTUI",
            targets: [
                "AgenticTUI",
            ]
        ),
        .library(
            name: "AgenticMacUI",
            targets: [
                "AgenticMacUI",
            ]
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
        .package(url: "https://github.com/leviouwendijk/Path.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Selection.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Sensitivity.git", branch: "master"),
        .package(
            url: "https://github.com/leviouwendijk/AgenticInterfaces.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/IO.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/AgenticIO.git",
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
            url: "https://github.com/leviouwendijk/Version.git",
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
            url: "https://github.com/leviouwendijk/ICS.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/Parsers.git",
            branch: "master"
        ),
    ],
    targets: [
        .target(
            name: "AgenticHost",
            dependencies: [
                .product(
                    name: "AgenticContextWindow",
                    package: "Agentic"
                ),
                .product(
                    name: "AgenticSessions",
                    package: "Agentic"
                ),
                .product(
                    name: "AgenticIntents",
                    package: "Agentic"
                ),
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
                    name: "Primitives",
                    package: "Primitives"
                ),
                .product(
                    name: "AgenticInterfaces",
                    package: "AgenticInterfaces"
                ),
                .product(
                    name: "AgenticIO",
                    package: "AgenticIO"
                ),
                .product(
                    name: "Workspace",
                    package: "Workspace"
                ),
                .product(
                    name: "Writers",
                    package: "Writers"
                ),
                .product(name: "Path", package: "Path"),
                .product(name: "PathParsing", package: "Path"),
                .product(name: "Selection", package: "Selection"),
            ]
        ),
        .target(
            name: "AgenticCommandLine",
            dependencies: [
                .product(
                    name: "AgenticSessions",
                    package: "Agentic"
                ),
                "AgenticHost",
                .product(name: "Writers", package: "Writers"),
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
                .product(name: "AgenticSensitivity", package: "Agentic"),
                .product(
                    name: "Workspace",
                    package: "Workspace"
                ),
                .product(
                    name: "AgenticInterfaces",
                    package: "AgenticInterfaces"
                ),
                .product(
                    name: "AgenticStandard",
                    package: "Agentic"
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
                .product(
                    name: "TerminalStructuredContent",
                    package: "Terminal"
                ),
                .product(
                    name: "ParsersStructuredContent",
                    package: "Parsers"
                ),
            ]
        ),
        .target(
            name: "AgenticTUI",
            dependencies: [
                "AgenticHost",
                "AgenticCommandLine",
                .product(name: "Version", package: "Version"),
                .product(name: "Agentic", package: "Agentic"),
                .product(name: "AgenticModels", package: "Agentic"),
                .product(name: "AgenticStandard", package: "Agentic"),
                .product(name: "AgenticHarness", package: "Agentic"),
                .product(name: "AgenticRuntime", package: "AgenticRuntime"),
                .product(name: "AgenticConfiguration", package: "Agentic"),
                .product(name: "AgenticSensitivity", package: "Agentic"),
                .product(name: "Sensitivity", package: "Sensitivity"),
                .product(name: "AgenticInterfaces", package: "AgenticInterfaces"),
                .product(name: "Workspace", package: "Workspace"),
                .product(name: "Writers", package: "Writers"),
                .product(name: "IO", package: "IO"),
                .product(name: "Primitives", package: "Primitives"),
                .product(name: "Arguments", package: "Arguments"),
                .product(name: "Clipboard", package: "Clipboard"),
                .product(name: "DSL", package: "DSL"),
                .product(name: "ErrorsDSL", package: "Errors"),
                .product(name: "Terminal", package: "Terminal"),
                .product(name: "Reporting", package: "Reporting"),
                .product(name: "ICS", package: "ICS"),
            ],
            path: "Sources/AgenticTUI"
        ),
        .target(
            name: "AgenticMacUI",
            dependencies: [
                "AgenticHost",
                .product(name: "Agentic", package: "Agentic"),
                .product(name: "AgenticRuntime", package: "AgenticRuntime"),
                .product(name: "AgenticConfiguration", package: "Agentic"),
                .product(name: "Writers", package: "Writers"),
            ],
            path: "Sources/AgenticMacUI"
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
