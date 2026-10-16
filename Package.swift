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
            path: "Sources/ClaudeBubble",
            // Const values for the App Intents metadata (the Focus filter); scripts/bundle.sh turns them into
            // Metadata.appintents, which Xcode would otherwise generate.
            swiftSettings: [.unsafeFlags(["-emit-const-values", "-Xfrontend", "-const-gather-protocols-file",
                                          "-Xfrontend", "\(Context.packageDirectory)/scripts/appintents-protocols.json"])]
        ),
        .testTarget(
            name: "ClaudeBubbleCoreTests",
            dependencies: ["ClaudeBubbleCore"],
            path: "Tests/ClaudeBubbleCoreTests"
        )
    ]
)
