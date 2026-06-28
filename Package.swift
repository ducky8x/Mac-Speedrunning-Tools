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
    targets: [
        .executableTarget(
            name: "MST",
            path: "Sources/MST"
        ),
        .testTarget(
            name: "MSTTests",
            dependencies: ["MST"],
            path: "Tests/MSTTests"
        )
    ]
)
