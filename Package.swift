// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftCodingAgent",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "SwiftCodingAgent", targets: ["SwiftCodingAgent"]),
        .executable(name: "SwiftCodingAgentExample", targets: ["SwiftCodingAgentExample"])
    ],
    targets: [
        .target(
            name: "SwiftCodingAgent",
            path: "Sources/SwiftCodingAgent"
        ),
        .testTarget(
            name: "SwiftCodingAgentTests",
            dependencies: ["SwiftCodingAgent"],
            path: "Tests/SwiftCodingAgentTests"
        ),
        .executableTarget(
            name: "SwiftCodingAgentExample",
            dependencies: ["SwiftCodingAgent"],
            path: "Examples/SwiftCodingAgentExample"
        )
    ]
)
