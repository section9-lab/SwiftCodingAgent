import Testing
@testable import SwiftAgent
import Foundation

private actor MockState {
    var index = 0
    func next() -> Int {
        let current = index
        index += 1
        return current
    }
}

private struct MockModel: AgentModel {
    let responses: [ModelResponse]
    let state = MockState()

    func generate(request: ModelRequest) async throws -> ModelResponse {
        let i = await state.next()
        if i < responses.count {
            return responses[i]
        }
        return ModelResponse(content: "done")
    }
}

struct AgentLoopTests {
    @Test
    func finalTextWithoutTool() async throws {
        let model = MockModel(responses: [ModelResponse(content: "hello")])
        let loop = AgentLoop(
            model: model,
            config: AgentLoopConfig(workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        )

        let result = try await loop.run(userInput: "hi")
        #expect(result.finalText == "hello")
        #expect(result.steps == 1)
    }

    @Test
    func toolCallStillWorks() async throws {
        let model = MockModel(
            responses: [
                ModelResponse(
                    content: "",
                    toolCalls: [
                        ToolCall(
                            id: "read-1",
                            name: "read",
                            argumentsJSON: "{\"path\":\"README.md\"}"
                        )
                    ]
                ),
                ModelResponse(content: "done")
            ]
        )

        let loop = AgentLoop(
            model: model,
            config: AgentLoopConfig(workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        )

        let result = try await loop.run(userInput: "read file")
        #expect(result.finalText == "done")
        #expect(result.steps == 2)
    }
}
