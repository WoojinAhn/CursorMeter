// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CursorMeter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CursorMeter",
            path: "Sources/CursorMeter"
        ),
        .testTarget(
            name: "CursorMeterTests",
            dependencies: ["CursorMeter"],
            path: "Tests/CursorMeterTests"
        ),
    ]
)
