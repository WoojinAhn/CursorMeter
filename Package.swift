// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CursorBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CursorBar",
            path: "Sources/CursorBar"
        ),
        .testTarget(
            name: "CursorBarTests",
            dependencies: ["CursorBar"],
            path: "Tests/CursorBarTests"
        ),
    ]
)
