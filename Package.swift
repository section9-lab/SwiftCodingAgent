// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftHarnessAgent",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        // Provider-agnostic LLM client layer. Use this directly if you only
        // want OpenAI / Anthropic API access without the agent runtime.
        .library(name: "SwiftAISDK", targets: ["SwiftAISDK"]),
        // Coding-agent runtime built on top of SwiftAISDK.
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
            name: "SwiftAISDK",
            dependencies: [
                .product(name: "EventSource", package: "EventSource")
            ],
            path: "Sources/SwiftAISDK"
        ),
        .target(
            name: "SwiftHarnessAgent",
            dependencies: ["SwiftAISDK"],
            path: "Sources/SwiftHarnessAgent"
        ),
        .testTarget(
            name: "SwiftAISDKTests",
            dependencies: ["SwiftAISDK"],
            path: "Tests/SwiftAISDKTests"
        ),
        .testTarget(
            name: "SwiftHarnessAgentTests",
            dependencies: ["SwiftHarnessAgent", "SwiftAISDK"],
            path: "Tests/SwiftHarnessAgentTests"
        ),
        .executableTarget(
            name: "SwiftHarnessAgentExample",
            dependencies: ["SwiftHarnessAgent"],
            path: "Examples/SwiftHarnessAgentExample"
        )
    ]
)
