import Testing
@testable import SwiftHarnessAgent
import Foundation

private struct DummyContext {
    static func make() -> ToolExecutionContext {
        ToolExecutionContext(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            executionPolicy: ToolExecutionPolicy(allowedRoots: [URL(fileURLWithPath: "/tmp")], bash: .disabled)
        )
    }
}

struct TodoWriteToolTests {
    @Test
    func initReplacesEntireListAndAutoPromotesFirstTask() async throws {
        let store = TodoStore()
        let tool = TodoWriteTool(store: store)

        let json = """
        {"ops":[{"op":"init","list":[{"phase":"Foundation","items":["Scaffold","Wire"]},{"phase":"Auth","items":["JWT"]}]}]}
        """
        let output = try await tool.run(argumentsJSON: json, context: DummyContext.make())

        #expect(output.contains("## Foundation"))
        #expect(output.contains("## Auth"))
        #expect(output.contains("[~] Scaffold"))
        #expect(output.contains("[ ] Wire"))
        #expect(output.contains("Progress: 0/3 completed"))

        let phases = await store.snapshot()
        #expect(phases.map(\.name) == ["Foundation", "Auth"])
        #expect(phases[0].tasks[0].status == .inProgress)
        #expect(phases[0].tasks[1].status == .pending)
    }

    @Test
    func doneAutoPromotesNextPendingTask() async throws {
        let store = TodoStore()
        let tool = TodoWriteTool(store: store)
        let ctx = DummyContext.make()

        _ = try await tool.run(
            argumentsJSON: """
            {"ops":[{"op":"init","list":[{"phase":"Phase","items":["First","Second","Third"]}]}]}
            """,
            context: ctx
        )

        let output = try await tool.run(
            argumentsJSON: #"{"ops":[{"op":"done","task":"First"}]}"#,
            context: ctx
        )

        #expect(output.contains("[x] First"))
        #expect(output.contains("[~] Second"))

        let phases = await store.snapshot()
        #expect(phases[0].tasks[0].status == .completed)
        #expect(phases[0].tasks[1].status == .inProgress)
        #expect(phases[0].tasks[2].status == .pending)
    }

    @Test
    func appendAddsItemsAndCreatesPhase() async throws {
        let store = TodoStore()
        let tool = TodoWriteTool(store: store)
        let ctx = DummyContext.make()

        _ = try await tool.run(
            argumentsJSON: #"{"ops":[{"op":"append","phase":"NewPhase","items":["A","B"]}]}"#,
            context: ctx
        )

        let phases = await store.snapshot()
        #expect(phases.count == 1)
        #expect(phases[0].name == "NewPhase")
        #expect(phases[0].tasks.map(\.content) == ["A", "B"])
    }

    @Test
    func dropAndRmReportErrorsForUnknownTargets() async throws {
        let store = TodoStore()
        let tool = TodoWriteTool(store: store)

        let output = try await tool.run(
            argumentsJSON: #"{"ops":[{"op":"drop","task":"Nonexistent"}]}"#,
            context: DummyContext.make()
        )
        #expect(output.contains("drop: task not found: Nonexistent"))
    }

    @Test
    func noteAttachesToTask() async throws {
        let store = TodoStore()
        let tool = TodoWriteTool(store: store)
        let ctx = DummyContext.make()

        _ = try await tool.run(
            argumentsJSON: """
            {"ops":[{"op":"init","list":[{"phase":"P","items":["Task A"]}]}]}
            """,
            context: ctx
        )
        let output = try await tool.run(
            argumentsJSON: #"{"ops":[{"op":"note","task":"Task A","text":"watch out for X"}]}"#,
            context: ctx
        )
        #expect(output.contains("↳ note: watch out for X"))
    }

    @Test
    func multipleOpsApplyInOrder() async throws {
        let store = TodoStore()
        let tool = TodoWriteTool(store: store)

        let json = """
        {"ops":[
            {"op":"init","list":[{"phase":"P","items":["A","B"]}]},
            {"op":"done","task":"A"},
            {"op":"append","phase":"P","items":["C"]}
        ]}
        """
        _ = try await tool.run(argumentsJSON: json, context: DummyContext.make())

        let phases = await store.snapshot()
        #expect(phases[0].tasks.map(\.content) == ["A", "B", "C"])
        #expect(phases[0].tasks[0].status == .completed)
        #expect(phases[0].tasks[1].status == .inProgress)
        #expect(phases[0].tasks[2].status == .pending)
    }
}
