// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MST",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MST", targets: ["MST"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
    ],
    targets: [
        .executableTarget(
            name: "MST",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/MST"
        ),
        .testTarget(
            name: "MSTTests",
            dependencies: ["MST"]
        )
    ]
)
