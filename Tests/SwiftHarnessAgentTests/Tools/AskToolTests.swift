import Testing
@testable import SwiftHarnessAgent
import Foundation

private struct AskCtx {
    static func make() -> ToolExecutionContext {
        ToolExecutionContext(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            executionPolicy: ToolExecutionPolicy(allowedRoots: [URL(fileURLWithPath: "/tmp")], bash: .disabled)
        )
    }
}

struct AskToolTests {
    @Test
    func handlerReceivesParsedQuestionsAndReturnsRendered() async throws {
        let tool = AskTool { questions in
            #expect(questions.count == 1)
            let q = questions[0]
            #expect(q.id == "auth")
            #expect(q.question == "Which authentication method?")
            #expect(q.options == ["JWT", "OAuth2", "Session cookies"])
            #expect(q.recommended == 0)
            #expect(q.multi == false)
            return [AskAnswer(id: "auth", selections: ["JWT"])]
        }

        let json = """
        {"questions":[{"id":"auth","question":"Which authentication method?","options":[{"label":"JWT"},{"label":"OAuth2"},{"label":"Session cookies"}],"recommended":0}]}
        """
        let output = try await tool.run(argumentsJSON: json, context: AskCtx.make())
        #expect(output.contains("Q: Which authentication method?"))
        #expect(output.contains("A: JWT"))
    }

    @Test
    func multiSelectIsForwarded() async throws {
        let tool = AskTool { questions in
            #expect(questions[0].multi == true)
            return [AskAnswer(id: "skills", selections: ["Auth", "Logging"])]
        }
        let json = """
        {"questions":[{"id":"skills","question":"Pick skills","options":[{"label":"Auth"},{"label":"Logging"},{"label":"Cache"}],"multi":true}]}
        """
        let output = try await tool.run(argumentsJSON: json, context: AskCtx.make())
        #expect(output.contains("A: Auth, Logging"))
    }

    @Test
    func customInputBranchIsRendered() async throws {
        let tool = AskTool { _ in
            [AskAnswer(id: "x", selections: [], customInput: "something else")]
        }
        let json = """
        {"questions":[{"id":"x","question":"Pick","options":[{"label":"A"}]}]}
        """
        let output = try await tool.run(argumentsJSON: json, context: AskCtx.make())
        #expect(output.contains("A: (custom) something else"))
    }

    @Test
    func handlerErrorPropagates() async {
        let tool = AskTool { _ in
            throw AskError.aborted
        }
        let json = """
        {"questions":[{"id":"x","question":"Pick","options":[{"label":"A"}]}]}
        """
        await #expect(throws: AskError.self) {
            _ = try await tool.run(argumentsJSON: json, context: AskCtx.make())
        }
    }

    @Test
    func mismatchedAnswerCountFails() async {
        let tool = AskTool { _ in [] }
        let json = """
        {"questions":[{"id":"x","question":"Pick","options":[{"label":"A"}]}]}
        """
        await #expect(throws: AskError.self) {
            _ = try await tool.run(argumentsJSON: json, context: AskCtx.make())
        }
    }
}
