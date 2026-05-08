import Testing
@testable import SwiftHarnessAgent
import Foundation

// MARK: - Streaming mock client

private struct StreamingMockClient: LLMClient {
    let scripts: [[LLMStreamEvent]]
    let cursor = ScriptCursor()

    actor ScriptCursor {
        var index = 0
        func next() -> Int { defer { index += 1 }; return index }
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let i = await cursor.next()
        let script = i < scripts.count ? scripts[i] : [.messageStop(LLMResponse(
            message: LLMMessage(role: .assistant, content: [.text("done")]),
            stopReason: .endTurn
        ))]
        for event in script {
            if case .messageStop(let response) = event {
                return response
            }
        }
        return LLMResponse(
            message: LLMMessage(role: .assistant, content: [.text("done")]),
            stopReason: .endTurn
        )
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let i = await cursor.next()
                let script = i < scripts.count ? scripts[i] : [.messageStop(LLMResponse(
                    message: LLMMessage(role: .assistant, content: [.text("done")]),
                    stopReason: .endTurn
                ))]
                for event in script {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Helpers

private func textStop(_ text: String) -> LLMStreamEvent {
    .messageStop(LLMResponse(
        message: LLMMessage(role: .assistant, content: [.text(text)]),
        stopReason: .endTurn
    ))
}

private func toolUseStop(_ text: String, uses: [LLMToolUse]) -> LLMStreamEvent {
    var content: [LLMContentBlock] = []
    if !text.isEmpty { content.append(.text(text)) }
    for use in uses { content.append(.toolUse(use)) }
    return .messageStop(LLMResponse(
        message: LLMMessage(role: .assistant, content: content),
        stopReason: .toolUse
    ))
}

struct AgentLoopStreamTests {
    @Test
    func textDeltasAreForwardedThenCompletes() async throws {
        let client = StreamingMockClient(scripts: [
            [
                .messageStart(LLMStreamMessageStart(providerResponseID: nil)),
                .blockStart(LLMStreamBlockStart(blockIndex: 0, kind: .text)),
                .textDelta("Hel"),
                .textDelta("lo, "),
                .textDelta("world"),
                .blockStop(LLMStreamBlockStop(blockIndex: 0)),
                textStop("Hello, world")
            ]
        ])

        let loop = AgentLoop(
            client: client,
            modelName: "mock",
            config: AgentLoopConfig(workingDirectory: URL(fileURLWithPath: "/tmp"))
        )

        var deltas: [String] = []
        var finalText: String?
        var sawAssistantTurn = false
        for try await event in loop.runStream(userInput: "hi") {
            switch event {
            case .textDelta(let s): deltas.append(s)
            case .assistantTurn(let text, let uses):
                sawAssistantTurn = true
                #expect(uses.isEmpty)
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
        let toolUses = [
            LLMToolUse(id: "1", name: "read", argumentsJSON: #"{"path":"a"}"#),
            LLMToolUse(id: "2", name: "read", argumentsJSON: #"{"path":"b"}"#)
        ]
        let client = StreamingMockClient(scripts: [
            [
                .messageStart(LLMStreamMessageStart(providerResponseID: nil)),
                .blockStart(LLMStreamBlockStart(blockIndex: 0, kind: .text)),
                .textDelta("Looking up files"),
                .blockStop(LLMStreamBlockStop(blockIndex: 0)),
                toolUseStop("Looking up files", uses: toolUses)
            ],
            [
                textStop("Done")
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
            client: client,
            modelName: "mock",
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
