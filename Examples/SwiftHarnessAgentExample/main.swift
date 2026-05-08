import SwiftHarnessAgent
import Foundation

@main
struct SwiftHarnessAgentExample {
    static func main() async throws {
        print("=== SwiftHarnessAgent Example ===\n")

        // EchoClient — no API key needed.
        let client = EchoClient()

        // Build the AgentSDK.
        let workingDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let agent = AgentSDK(
            client: client,
            modelName: "echo",
            workingDirectory: workingDir,
            executionPolicy: ToolExecutionPolicy(
                allowedRoots: [workingDir],
                bash: .disabled
            ),
            maxSteps: 5
        )

        print("User: Hello, SwiftHarnessAgent!")
        let result = try await agent.run(prompt: "Hello, SwiftHarnessAgent!")
        print("Agent: \(result.finalText)")
        print("\nSteps: \(result.steps)")

        print("\n--- Message History ---")
        let history = await agent.history()
        for msg in history {
            let preview = String(msg.text.prefix(100))
            print("[\(msg.role)] \(preview)")
        }
    }
}
