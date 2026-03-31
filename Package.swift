// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftAgent",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "SwiftAgent", targets: ["SwiftAgent"]),
        .executable(name: "SwiftAgentExample", targets: ["SwiftAgentExample"])
    ],
    targets: [
        .target(
            name: "SwiftAgent",
            path: "Sources/SwiftAgent"
        ),
        .testTarget(
            name: "SwiftAgentTests",
            dependencies: ["SwiftAgent"],
            path: "Tests/SwiftAgentTests"
        ),
        .executableTarget(
            name: "SwiftAgentExample",
            dependencies: ["SwiftAgent"],
            path: "Examples/SwiftAgentExample"
        )
    ]
)
