import Testing
@testable import SwiftHarnessAgent
import Foundation

/// A scripted model that replays a fixed sequence of responses. Each call to
/// `generate` advances the cursor; the same model instance is shared across
/// multiple subagent loops, but the responses for each loop are short enough
/// (one assistant reply, no tool calls) that we don't have to track per-loop
/// state.
private actor SequenceState {
    var index = 0
    func next() -> Int {
        let i = index
        index += 1
        return i
    }
}

private struct ScriptedModel: AgentModel {
    let responses: [ModelResponse]
    let state = SequenceState()

    func generate(request: ModelRequest) async throws -> ModelResponse {
        let i = await state.next()
        if i < responses.count { return responses[i] }
        return ModelResponse(content: "done")
    }
}

/// Each subagent gets its own fresh ScriptedModel via the factory, so the
/// per-subagent cursor starts at 0 every time.
private func makeFactory(answer: String) -> @Sendable (SubagentDefinition) -> any AgentModel {
    return { _ in
        ScriptedModel(responses: [ModelResponse(content: answer)])
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
            modelFactory: makeFactory(answer: "investigation summary"),
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

        // Order is preserved by index, not by completion time.
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
            modelFactory: makeFactory(answer: "ok"),
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
            modelFactory: makeFactory(answer: ""),
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
            modelFactory: makeFactory(answer: ""),
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
