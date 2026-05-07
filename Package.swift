// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftHarnessAgent",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "SwiftHarnessAgent", targets: ["SwiftHarnessAgent"]),
        .executable(name: "SwiftHarnessAgentExample", targets: ["SwiftHarnessAgentExample"])
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
            name: "SwiftHarnessAgent",
            dependencies: [
                .product(name: "EventSource", package: "EventSource")
            ],
            path: "Sources/SwiftHarnessAgent"
        ),
        .testTarget(
            name: "SwiftHarnessAgentTests",
            dependencies: ["SwiftHarnessAgent"],
            path: "Tests/SwiftHarnessAgentTests"
        ),
        .executableTarget(
            name: "SwiftHarnessAgentExample",
            dependencies: ["SwiftHarnessAgent"],
            path: "Examples/SwiftHarnessAgentExample"
        )
    ]
)
