import Testing
@testable import SwiftHarnessAgent
import Foundation

private actor SequenceState {
    var index = 0
    func next() -> Int {
        let i = index
        index += 1
        return i
    }
}

/// Scripted LLM client that replays a fixed list of responses. One instance
/// per subagent spawn; the shared coordinator factory below builds a fresh
/// one each time so the cursor always starts at zero.
private struct ScriptedClient: LLMClient {
    let responses: [LLMResponse]
    let state = SequenceState()

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let i = await state.next()
        if i < responses.count { return responses[i] }
        return LLMResponse(
            message: LLMMessage(role: .assistant, content: [.text("done")]),
            stopReason: .endTurn
        )
    }
}

private func makeFactory(answer: String) -> @Sendable (SubagentDefinition) -> (any LLMClient, String) {
    return { _ in
        (
            ScriptedClient(responses: [
                LLMResponse(
                    message: LLMMessage(role: .assistant, content: [.text(answer)]),
                    stopReason: .endTurn
                )
            ]),
            "scripted-model"
        )
    }
}

private func makeContext() -> ToolExecutionContext {
    ToolExecutionContext(
        workingDirectory: URL(fileURLWithPath: "/tmp"),
        executionPolicy: ToolExecutionPolicy(allowedRoots: [URL(fileURLWithPath: "/tmp")], bash: .disabled)
    )
}

struct TaskToolTests {
    @Test
    func runsBatchAndReturnsResultsInOrder() async throws {
        let agent = SubagentDefinition(
            id: "explorer",
            displayName: "Explorer",
            description: "Read-only investigation",
            systemPrompt: "You are an explorer.",
            tools: [],
            maxSteps: 2
        )

        let coordinator = TaskCoordinator(
            definitions: [agent],
            clientFactory: makeFactory(answer: "investigation summary"),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            executionPolicy: ToolExecutionPolicy(allowedRoots: [URL(fileURLWithPath: "/tmp")], bash: .disabled),
            maxConcurrency: 2
        )

        let tool = TaskTool(coordinator: coordinator)
        let json = """
        {
          "agent": "explorer",
          "context": "Goal: map the auth subsystem",
          "tasks": [
            {"id":"AuthLoader","description":"map loader","assignment":"List files under src/auth"},
            {"id":"AuthRouter","description":"map router","assignment":"List files under src/router"}
          ]
        }
        """

        let output = try await tool.run(argumentsJSON: json, context: makeContext())

        let authLoaderRange = output.range(of: "Task AuthLoader")
        let authRouterRange = output.range(of: "Task AuthRouter")
        #expect(authLoaderRange != nil)
        #expect(authRouterRange != nil)
        if let a = authLoaderRange, let b = authRouterRange {
            #expect(a.lowerBound < b.lowerBound)
        }
        #expect(output.contains("success"))
        #expect(output.contains("investigation summary"))
    }

    @Test
    func unknownAgentIdFailsTaskWithoutAbortingBatch() async throws {
        let known = SubagentDefinition(
            id: "known",
            displayName: "Known",
            description: "ok",
            systemPrompt: "",
            maxSteps: 2
        )
        let coordinator = TaskCoordinator(
            definitions: [known],
            clientFactory: makeFactory(answer: "ok"),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            executionPolicy: ToolExecutionPolicy(allowedRoots: [URL(fileURLWithPath: "/tmp")], bash: .disabled)
        )

        let tool = TaskTool(coordinator: coordinator)
        let json = """
        {
          "agent": "missing",
          "tasks": [
            {"id":"X","description":"x","assignment":"do x"}
          ]
        }
        """
        let output = try await tool.run(argumentsJSON: json, context: makeContext())
        #expect(output.contains("failed"))
        #expect(output.contains("unknown agent: missing"))
    }

    @Test
    func duplicateTaskIDsFailValidation() async {
        let coordinator = TaskCoordinator(
            definitions: [],
            clientFactory: makeFactory(answer: ""),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            executionPolicy: ToolExecutionPolicy(allowedRoots: [URL(fileURLWithPath: "/tmp")], bash: .disabled)
        )
        let tool = TaskTool(coordinator: coordinator)
        let json = """
        {
          "agent": "x",
          "tasks": [
            {"id":"A","description":"a","assignment":"do"},
            {"id":"A","description":"b","assignment":"do"}
          ]
        }
        """
        await #expect(throws: ToolError.self) {
            _ = try await tool.run(argumentsJSON: json, context: makeContext())
        }
    }

    @Test
    func emptyAssignmentFailsValidation() async {
        let coordinator = TaskCoordinator(
            definitions: [],
            clientFactory: makeFactory(answer: ""),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            executionPolicy: ToolExecutionPolicy(allowedRoots: [URL(fileURLWithPath: "/tmp")], bash: .disabled)
        )
        let tool = TaskTool(coordinator: coordinator)
        let json = """
        {
          "agent": "x",
          "tasks": [
            {"id":"A","description":"a","assignment":"   "}
          ]
        }
        """
        await #expect(throws: ToolError.self) {
            _ = try await tool.run(argumentsJSON: json, context: makeContext())
        }
    }
}
