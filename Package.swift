// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacSpeedrunningTools",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacSpeedrunningTools", targets: ["MacSpeedrunningTools"])
    ],
    targets: [
        .executableTarget(
            name: "MacSpeedrunningTools",
            path: "Sources/MacSpeedrunningTools"
        )
    ]
)
