import Testing
@testable import SwiftHarnessAgent
import Foundation

private actor MockState {
    var index = 0
    func next() -> Int {
        let current = index
        index += 1
        return current
    }
}

private actor LockedBox<Value: Sendable> {
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ newValue: Value) {
        value = newValue
    }

    func get() -> Value {
        value
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

private struct RecordingTool: AgentTool {
    let name = "record"
    let description = "Record execution context"
    let argumentSchemaJSON = "{}"
    let onRun: @Sendable (ToolExecutionContext) async throws -> String

    func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        try await onRun(context)
    }
}

struct AgentLoopTests {
    @Test
    func workingDirectoryInitializerStillIncludesWorkingDirectory() {
        let workingDirectory = URL(fileURLWithPath: "/tmp/workspace")
        let policy = ToolExecutionPolicy(
            workingDirectory: workingDirectory,
            allowedRoots: [
                URL(fileURLWithPath: "/tmp/workspace"),
                URL(fileURLWithPath: "/tmp/shared")
            ]
        )

        #expect(policy.fileAccess.allowedRoots.map(\.path) == ["/tmp/workspace", "/tmp/shared"])
    }

    @Test
    func agentLoopConfigCanUseExplicitRootsWithoutWorkingDirectory() {
        let workingDirectory = URL(fileURLWithPath: "/tmp/agent-home")
        let config = AgentLoopConfig(
            workingDirectory: workingDirectory,
            allowedRoots: [URL(fileURLWithPath: "/tmp/project")]
        )

        #expect(config.workingDirectory.path == "/tmp/agent-home")
        #expect(config.allowedRoots.map(\.path) == ["/tmp/project"])
    }

    @Test
    func toolSpecificExecutionContextOverridesDefaultContext() async throws {
        let state = LockedBox<ToolExecutionContext?>(nil)
        let tool = RecordingTool { context in
            await state.set(context)
            return "ok"
        }
        let model = MockModel(
            responses: [
                ModelResponse(
                    content: "",
                    toolCalls: [ToolCall(name: "record", argumentsJSON: "{}")]
                ),
                ModelResponse(content: "done")
            ]
        )

        let loop = AgentLoop(
            model: model,
            tools: [tool],
            config: AgentLoopConfig(
                workingDirectory: URL(fileURLWithPath: "/tmp/agent-home"),
                allowedRoots: [URL(fileURLWithPath: "/tmp/project")],
                toolExecutionContexts: [
                    "record": ToolExecutionContext(
                        workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                        executionPolicy: ToolExecutionPolicy(
                            allowedRoots: [URL(fileURLWithPath: "/tmp/project"), URL(fileURLWithPath: "/tmp/shared")],
                            bash: .disabled
                        )
                    )
                ]
            )
        )

        let result = try await loop.run(userInput: "run tool")
        #expect(result.finalText == "done")

        let recorded = await state.get()
        #expect(recorded?.workingDirectory.path == "/tmp/project")
        #expect(recorded?.allowedRoots.map(\.path) == ["/tmp/project", "/tmp/shared"])
        if case .disabled? = recorded?.bashExecutionPolicy {
            #expect(Bool(true))
        } else {
            Issue.record("Expected disabled bash policy")
        }
    }

    @Test
    func bashCanBeDisabledByPolicy() async throws {
        let tool = BashTool()
        let context = ToolExecutionContext(
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            executionPolicy: ToolExecutionPolicy(
                workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                bash: .disabled
            )
        )

        await #expect(throws: ToolError.self) {
            try await tool.run(
                argumentsJSON: #"{"command":"pwd"}"#,
                context: context
            )
        }
    }

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

    @Test
    func parallelToolCallsAreGroupedIntoOneAssistantMessage() async throws {
        let counter = LockedBox(0)
        let tool = RecordingTool { _ in
            await counter.set((await counter.get()) + 1)
            return "ok"
        }

        let model = MockModel(
            responses: [
                ModelResponse(
                    content: "running",
                    toolCalls: [
                        ToolCall(id: "a", name: "record", argumentsJSON: "{}"),
                        ToolCall(id: "b", name: "record", argumentsJSON: "{}"),
                        ToolCall(id: "c", name: "record", argumentsJSON: "{}")
                    ]
                ),
                ModelResponse(content: "all done")
            ]
        )

        let loop = AgentLoop(
            model: model,
            tools: [tool],
            config: AgentLoopConfig(
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                parallelToolCalls: true
            )
        )

        let result = try await loop.run(userInput: "go")
        #expect(result.finalText == "all done")
        #expect(await counter.get() == 3)

        // Verify history shape: one assistant message with 3 tool calls,
        // followed by one tool message with 3 results — not 6 interleaved messages.
        let history = await loop.history()
        let assistantWithCalls = history.first { $0.role == .assistant && !$0.toolCalls.isEmpty }
        let toolMessage = history.first { $0.role == .tool }
        #expect(assistantWithCalls?.toolCalls.count == 3)
        #expect(toolMessage?.toolResults.count == 3)
        #expect(toolMessage?.toolResults.map(\.toolCallID) == ["a", "b", "c"])
    }
}
