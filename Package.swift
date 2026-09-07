// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "AgenticHost",
    products: [
        .library(
            name: "AgenticHost",
            targets: ["AgenticHost"]
        ),
    ],
    targets: [
        .target(
            name: "AgenticHost"
        ),
    ],
    swiftLanguageModes: [.v6]
)
