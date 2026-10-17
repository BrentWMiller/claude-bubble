// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ClaudeBubble",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(name: "ClaudeBubbleCore", path: "Sources/ClaudeBubbleCore"),
        // The Claude Code hook's logic: Foundation only, so the hook binary starts fast.
        .target(name: "HookCore", path: "Sources/HookCore"),
        .executableTarget(name: "claude-bubble-hook", dependencies: ["HookCore"], path: "Sources/claude-bubble-hook"),
        .executableTarget(
            name: "ClaudeBubble",
            dependencies: ["ClaudeBubbleCore", "HookCore"],
            path: "Sources/ClaudeBubble"
        ),
        .testTarget(
            name: "ClaudeBubbleCoreTests",
            dependencies: ["ClaudeBubbleCore", "HookCore"],
            path: "Tests/ClaudeBubbleCoreTests"
        )
    ]
)
