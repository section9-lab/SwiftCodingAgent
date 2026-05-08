import Testing
@testable import SwiftHarnessAgent
import Foundation

// MARK: - Test doubles

private actor RequestRecorder {
    var captured: [[LLMMessage]] = []
    func record(_ messages: [LLMMessage]) { captured.append(messages) }
    func all() -> [[LLMMessage]] { captured }
}

private struct ScriptedClient: LLMClient {
    let recorder: RequestRecorder?
    let responses: [LLMResponse]
    let cursor = Cursor()

    actor Cursor {
        var i = 0
        func next() -> Int { defer { i += 1 }; return i }
    }

    init(_ responses: [LLMResponse], recorder: RequestRecorder? = nil) {
        self.responses = responses
        self.recorder = recorder
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        await recorder?.record(request.messages)
        let idx = await cursor.next()
        if idx < responses.count { return responses[idx] }
        return LLMResponse(
            message: LLMMessage(role: .assistant, content: [.text("done")]),
            stopReason: .endTurn
        )
    }
}

/// Stand-in summariser: each call returns the next scripted summary string.
/// Empty-string responses simulate failure (loop's "empty summary" path).
private struct ScriptedSummarizer: LLMClient {
    let scripts: [String]
    let cursor = Cursor()

    actor Cursor {
        var i = 0
        func next() -> Int { defer { i += 1 }; return i }
    }

    init(_ scripts: [String]) {
        self.scripts = scripts
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let idx = await cursor.next()
        let text = idx < scripts.count ? scripts[idx] : ""
        return LLMResponse(
            message: LLMMessage(role: .assistant, content: [.text(text)]),
            stopReason: .endTurn
        )
    }
}

// MARK: - Builders

private func assistantResponse(
    _ text: String,
    toolUses: [LLMToolUse] = [],
    inputTokens: Int? = nil
) -> LLMResponse {
    var content: [LLMContentBlock] = []
    if !text.isEmpty { content.append(.text(text)) }
    for use in toolUses { content.append(.toolUse(use)) }
    return LLMResponse(
        message: LLMMessage(role: .assistant, content: content),
        stopReason: toolUses.isEmpty ? .endTurn : .toolUse,
        usage: inputTokens.map { LLMUsage(inputTokens: $0) }
    )
}

// MARK: - Tests

struct CompactionTests {
    /// `usage.inputTokens` reported by the model wins over the heuristic
    /// estimator. As soon as it crosses the threshold, compaction triggers.
    @Test
    func compactionTriggersFromReportedUsage() async throws {
        let recorder = RequestRecorder()
        let client = ScriptedClient(
            [
                assistantResponse("first answer", inputTokens: 90_000),
                assistantResponse("second answer", inputTokens: 95_000),
                assistantResponse("third answer")
            ],
            recorder: recorder
        )
        let summarizer = ScriptedSummarizer(["## Goal\nbuild stuff\n## Next Steps\nfollow up"])

        let loop = AgentLoop(
            client: client,
            modelName: "scripted",
            summarizer: summarizer,
            summarizerModelName: "summary",
            config: AgentLoopConfig(
                maxSteps: 3,
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                compaction: CompactionConfig(
                    modelContextWindow: 100_000,
                    reserveTokens: 16_000,
                    keepRecentTokens: 1,
                    minMessagesToCompact: 1
                )
            )
        )

        _ = try await loop.run(userInput: "hello world")
        _ = try await loop.run(userInput: "another question")
        _ = try await loop.run(userInput: "third one please")

        let captured = await recorder.all()
        let sawSummary = captured.contains { msgs in
            msgs.contains { $0.role == .user && $0.text.hasPrefix("[Compaction summary") }
        }
        #expect(sawSummary, "expected at least one request to include the compaction summary")
    }

    @Test
    func smallConversationDoesNotTriggerCompaction() async throws {
        let recorder = RequestRecorder()
        let client = ScriptedClient(
            [assistantResponse("ok")],
            recorder: recorder
        )
        let summarizer = ScriptedSummarizer(["should-not-be-called"])

        let loop = AgentLoop(
            client: client,
            modelName: "scripted",
            summarizer: summarizer,
            config: AgentLoopConfig(
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                compaction: CompactionConfig()
            )
        )

        _ = try await loop.run(userInput: "hi")

        let captured = await recorder.all()
        let sawSummary = captured.contains { msgs in
            msgs.contains { $0.role == .user && $0.text.hasPrefix("[Compaction summary") }
        }
        #expect(!sawSummary)
    }

    @Test
    func firstUserMessageIsAnchoredAcrossCompaction() async throws {
        let recorder = RequestRecorder()
        let client = ScriptedClient(
            [
                assistantResponse("a", inputTokens: 90_000),
                assistantResponse("b", inputTokens: 95_000),
                assistantResponse("c")
            ],
            recorder: recorder
        )
        let summarizer = ScriptedSummarizer([
            "## Goal\nthe goal\n## Next Steps\nnext"
        ])

        let loop = AgentLoop(
            client: client,
            modelName: "scripted",
            summarizer: summarizer,
            config: AgentLoopConfig(
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                compaction: CompactionConfig(
                    modelContextWindow: 100_000,
                    reserveTokens: 16_000,
                    keepRecentTokens: 1,
                    minMessagesToCompact: 1
                )
            )
        )

        let originalGoal = "FIRST_USER_GOAL_MARKER"
        _ = try await loop.run(userInput: originalGoal)
        _ = try await loop.run(userInput: "follow-up question")
        _ = try await loop.run(userInput: "yet another follow-up")

        let all = await recorder.all()
        for msgs in all {
            let hasOriginal = msgs.contains { $0.role == .user && $0.text == originalGoal }
            #expect(hasOriginal, "first user message lost from request")
        }
    }

    @Test
    func forceDropsAfterRepeatedSummarizerFailures() async throws {
        let recorder = RequestRecorder()
        let client = ScriptedClient(
            (0..<6).map { i in
                assistantResponse("answer-\(i)", inputTokens: 90_000 + i)
            },
            recorder: recorder
        )
        let summarizer = ScriptedSummarizer(["", "", "", "", "", ""])

        let loop = AgentLoop(
            client: client,
            modelName: "scripted",
            summarizer: summarizer,
            config: AgentLoopConfig(
                maxSteps: 6,
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                compaction: CompactionConfig(
                    modelContextWindow: 100_000,
                    reserveTokens: 16_000,
                    keepRecentTokens: 1,
                    minMessagesToCompact: 1,
                    maxConsecutiveFailures: 2
                )
            )
        )

        _ = try await loop.run(userInput: "first")
        _ = try await loop.run(userInput: "second")
        _ = try await loop.run(userInput: "third")
        _ = try await loop.run(userInput: "fourth")

        let summary = await loop.currentCompactionSummary() ?? ""
        #expect(summary.contains("dropped after repeated summarisation failures"),
               "fallback placeholder not installed: \(summary)")
    }

    @Test
    func cutPointLandsOnTurnBoundary() async throws {
        let recorder = RequestRecorder()

        struct DummyTool: AgentTool {
            let name = "noop"
            let description = "Does nothing"
            let argumentSchemaJSON = "{}"
            func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
                "tool-output"
            }
        }

        let client = ScriptedClient(
            [
                assistantResponse(
                    "thinking",
                    toolUses: [LLMToolUse(id: "1", name: "noop", argumentsJSON: "{}")],
                    inputTokens: 90_000
                ),
                assistantResponse("done one", inputTokens: 92_000),
                assistantResponse(
                    "thinking2",
                    toolUses: [LLMToolUse(id: "2", name: "noop", argumentsJSON: "{}")],
                    inputTokens: 95_000
                ),
                assistantResponse("done two", inputTokens: 96_000),
                assistantResponse("done three")
            ],
            recorder: recorder
        )
        let summarizer = ScriptedSummarizer([
            "## Progress\nstep 1 done", "## Progress\nstep 2 done"
        ])

        let loop = AgentLoop(
            client: client,
            modelName: "scripted",
            summarizer: summarizer,
            tools: [DummyTool()],
            config: AgentLoopConfig(
                maxSteps: 4,
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                compaction: CompactionConfig(
                    modelContextWindow: 100_000,
                    reserveTokens: 16_000,
                    keepRecentTokens: 1,
                    minMessagesToCompact: 1
                )
            )
        )

        _ = try await loop.run(userInput: "user-1")
        _ = try await loop.run(userInput: "user-2")
        _ = try await loop.run(userInput: "user-3")

        // Any captured request: every tool_result must have a preceding
        // tool_use with the same id, and vice versa. A cut landing mid-turn
        // would break one of those invariants.
        let all = await recorder.all()
        for msgs in all {
            var pendingToolUses = Set<String>()
            for msg in msgs {
                if msg.role == .assistant {
                    for use in msg.toolUses { pendingToolUses.insert(use.id) }
                }
                if msg.role == .tool {
                    for result in msg.toolResults {
                        #expect(pendingToolUses.contains(result.toolUseID),
                               "tool_result \(result.toolUseID) without preceding tool_use")
                        pendingToolUses.remove(result.toolUseID)
                    }
                }
            }
            #expect(pendingToolUses.isEmpty,
                   "request ended with unresolved tool_use ids: \(pendingToolUses)")
        }
    }

    @Test
    func usageBeatsEstimator() async throws {
        let recorder = RequestRecorder()
        let bigText = String(repeating: "x", count: 400_000)
        let client = ScriptedClient(
            [
                assistantResponse(bigText, inputTokens: 1_000),
                assistantResponse("more", inputTokens: 1_500)
            ],
            recorder: recorder
        )
        let summarizer = ScriptedSummarizer(["should-not-fire"])

        let loop = AgentLoop(
            client: client,
            modelName: "scripted",
            summarizer: summarizer,
            config: AgentLoopConfig(
                maxSteps: 2,
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                compaction: CompactionConfig(
                    modelContextWindow: 100_000,
                    reserveTokens: 16_000,
                    keepRecentTokens: 1,
                    minMessagesToCompact: 1
                )
            )
        )

        _ = try await loop.run(userInput: "hello")
        _ = try await loop.run(userInput: "again")

        let all = await recorder.all()
        let sawSummary = all.contains { msgs in
            msgs.contains { $0.role == .user && $0.text.hasPrefix("[Compaction summary") }
        }
        #expect(!sawSummary, "compaction triggered despite low reported usage")
    }
}
