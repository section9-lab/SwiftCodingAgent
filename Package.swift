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
    dependencies: [
        // Spec-compliant SSE parser. Used to consume OpenAI/NIM/Anthropic
        // streaming responses byte-by-byte without tripping over edge cases
        // in `URLSession.AsyncBytes.lines` (which can collapse the empty
        // separator line between SSE events on some platforms).
        .package(url: "https://github.com/mattt/EventSource.git", from: "1.4.0")
    ],
    targets: [
        .target(
            name: "SwiftCodingAgent",
            dependencies: [
                .product(name: "EventSource", package: "EventSource")
            ],
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
