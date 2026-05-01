import Testing
@testable import SwiftCodingAgent
import Foundation

struct SSEParserTests {
    @Test
    func splitsEventsOnBlankLines() {
        var parser = SSEParser()
        let events = parser.feed("data: {\"a\":1}\n\ndata: {\"b\":2}\n\n")
        #expect(events == [#"{"a":1}"#, #"{"b":2}"#])
    }

    @Test
    func handlesPartialChunks() {
        var parser = SSEParser()
        var events = parser.feed("data: {\"hel")
        #expect(events.isEmpty)
        events = parser.feed("lo\":1}\n\n")
        #expect(events == [#"{"hello":1}"#])
    }

    @Test
    func joinsMultipleDataLines() {
        var parser = SSEParser()
        let events = parser.feed("data: line1\ndata: line2\n\n")
        #expect(events == ["line1\nline2"])
    }

    @Test
    func ignoresCommentsAndOtherFields() {
        var parser = SSEParser()
        let events = parser.feed(": keep-alive\nevent: ping\nid: 1\ndata: ok\n\n")
        #expect(events == ["ok"])
    }

    @Test
    func handlesCRLF() {
        var parser = SSEParser()
        let events = parser.feed("data: hi\r\n\r\n")
        #expect(events == ["hi"])
    }

    @Test
    func passesThroughDoneSentinel() {
        var parser = SSEParser()
        let events = parser.feed("data: [DONE]\n\n")
        #expect(events == ["[DONE]"])
    }
}

// MARK: - Stream-aware mock model

private struct StreamingMockModel: AgentModel {
    let scripts: [[ModelStreamEvent]]
    let cursor = ScriptCursor()

    actor ScriptCursor {
        var index = 0
        func next() -> Int { defer { index += 1 }; return index }
    }

    func generate(request: ModelRequest) async throws -> ModelResponse {
        // Walk this turn's script and synthesise a non-streaming response.
        let i = await cursor.next()
        let script = i < scripts.count ? scripts[i] : [.completed(ModelResponse(content: "done"))]
        var text = ""
        var calls: [ToolCall] = []
        for event in script {
            switch event {
            case .textDelta(let s): text += s
            case .toolCall(let c): calls.append(c)
            case .completed(let r):
                if text.isEmpty { text = r.content }
                if calls.isEmpty { calls = r.toolCalls }
            }
        }
        return ModelResponse(content: text, toolCalls: calls)
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let i = await cursor.next()
                let script = i < scripts.count ? scripts[i] : [.completed(ModelResponse(content: "done"))]
                for event in script {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct AgentLoopStreamTests {
    @Test
    func textDeltasAreForwardedThenCompletes() async throws {
        let model = StreamingMockModel(scripts: [
            [
                .textDelta("Hel"),
                .textDelta("lo, "),
                .textDelta("world"),
                .completed(ModelResponse(content: "Hello, world"))
            ]
        ])

        let loop = AgentLoop(
            model: model,
            config: AgentLoopConfig(workingDirectory: URL(fileURLWithPath: "/tmp"))
        )

        var deltas: [String] = []
        var finalText: String?
        var sawAssistantTurn = false
        for try await event in loop.runStream(userInput: "hi") {
            switch event {
            case .textDelta(let s): deltas.append(s)
            case .assistantTurn(let text, let calls):
                sawAssistantTurn = true
                #expect(calls.isEmpty)
                #expect(text == "Hello, world")
            case .completed(let result): finalText = result.finalText
            default: break
            }
        }

        #expect(deltas == ["Hel", "lo, ", "world"])
        #expect(sawAssistantTurn)
        #expect(finalText == "Hello, world")
    }

    @Test
    func toolCallsArriveAsBatchedEvents() async throws {
        let model = StreamingMockModel(scripts: [
            [
                .textDelta("Looking up files"),
                .toolCall(ToolCall(id: "1", name: "read", argumentsJSON: #"{"path":"a"}"#)),
                .toolCall(ToolCall(id: "2", name: "read", argumentsJSON: #"{"path":"b"}"#)),
                .completed(ModelResponse(
                    content: "Looking up files",
                    toolCalls: [
                        ToolCall(id: "1", name: "read", argumentsJSON: #"{"path":"a"}"#),
                        ToolCall(id: "2", name: "read", argumentsJSON: #"{"path":"b"}"#)
                    ]
                ))
            ],
            [
                .textDelta("Done"),
                .completed(ModelResponse(content: "Done"))
            ]
        ])

        struct DummyTool: AgentTool {
            let name = "read"
            let description = "Read"
            let argumentSchemaJSON = "{}"
            func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
                "content-of-\(argumentsJSON)"
            }
        }

        let loop = AgentLoop(
            model: model,
            tools: [DummyTool()],
            config: AgentLoopConfig(workingDirectory: URL(fileURLWithPath: "/tmp"))
        )

        var toolStarts = 0
        var toolFinishes = 0
        var finalText: String?
        for try await event in loop.runStream(userInput: "hi") {
            switch event {
            case .toolStarted: toolStarts += 1
            case .toolFinished: toolFinishes += 1
            case .completed(let r): finalText = r.finalText
            default: break
            }
        }

        #expect(toolStarts == 2)
        #expect(toolFinishes == 2)
        #expect(finalText == "Done")
    }
}
