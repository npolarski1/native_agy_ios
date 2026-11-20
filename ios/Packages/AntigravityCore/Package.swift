// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "AntigravityCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AntigravityCore",
            targets: ["AntigravityCore"]
        )
    ],
    targets: [
        .target(
            name: "AntigravityCore",
            path: "Sources/AntigravityCore"
        ),
        .testTarget(
            name: "AntigravityCoreTests",
            dependencies: ["AntigravityCore"],
            path: "Tests/AntigravityCoreTests"
        )
    ]
)
