import SwiftCodingAgent
import Foundation

@main
struct SwiftCodingAgentExample {
    static func main() async throws {
        print("=== SwiftCodingAgent Example ===\n")
        
        // 使用 EchoModel（不需要 API key）
        let model = EchoModel()
        
        // 创建 AgentSDK 实例
        let workingDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let agent = AgentSDK(
            model: model,
            workingDirectory: workingDir,
            executionPolicy: ToolExecutionPolicy(
                allowedRoots: [workingDir],
                bash: .disabled
            ),
            maxSteps: 5
        )
        
        // 运行 agent
        print("User: Hello, SwiftCodingAgent!")
        let result = try await agent.run(prompt: "Hello, SwiftCodingAgent!")
        print("Agent: \(result.finalText)")
        print("\nSteps: \(result.steps)")
        
        // 显示历史
        print("\n--- Message History ---")
        let history = await agent.history()
        for msg in history {
            print("[\(msg.role)] \(msg.content.prefix(100))...")
        }
    }
}
