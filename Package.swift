// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ClaudeBubble",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(name: "ClaudeBubbleCore", path: "Sources/ClaudeBubbleCore"),
        .executableTarget(
            name: "ClaudeBubble",
            dependencies: ["ClaudeBubbleCore"],
            path: "Sources/ClaudeBubble"
        ),
        .testTarget(
            name: "ClaudeBubbleCoreTests",
            dependencies: ["ClaudeBubbleCore"],
            path: "Tests/ClaudeBubbleCoreTests"
        )
    ]
)
