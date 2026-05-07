import Testing
@testable import SwiftHarnessAgent
import Foundation

// MARK: - Test doubles

private actor RequestRecorder {
    var captured: [[AgentMessage]] = []
    func record(_ messages: [AgentMessage]) { captured.append(messages) }
    func all() -> [[AgentMessage]] { captured }
}

private struct ScriptedModel: AgentModel {
    let recorder: RequestRecorder?
    let responses: [ModelResponse]
    let cursor = Cursor()

    actor Cursor {
        var i = 0
        func next() -> Int { defer { i += 1 }; return i }
    }

    init(_ responses: [ModelResponse], recorder: RequestRecorder? = nil) {
        self.responses = responses
        self.recorder = recorder
    }

    func generate(request: ModelRequest) async throws -> ModelResponse {
        await recorder?.record(request.messages)
        let idx = await cursor.next()
        if idx < responses.count { return responses[idx] }
        return ModelResponse(content: "done")
    }
}

/// Stand-in summariser: each call returns the next scripted summary string.
/// Empty-string responses simulate failure (loop's "empty summary" path).
private struct ScriptedSummarizer: AgentModel {
    let scripts: [String]
    let cursor = Cursor()

    actor Cursor {
        var i = 0
        func next() -> Int { defer { i += 1 }; return i }
    }

    init(_ scripts: [String]) {
        self.scripts = scripts
    }

    func generate(request: ModelRequest) async throws -> ModelResponse {
        let idx = await cursor.next()
        let text = idx < scripts.count ? scripts[idx] : ""
        return ModelResponse(content: text)
    }
}

// MARK: - Helpers

/// Builds a conversation long enough to cross the `keepRecentTokens` budget at
/// least once. Each pair is one user turn + one assistant turn, designed so
/// that turn boundaries exist at predictable indices.
private func makeChattyResponses(turns: Int, padding: String) -> [ModelResponse] {
    (0..<turns).map { idx in
        ModelResponse(
            content: "reply-\(idx) \(padding)",
            toolCalls: [],
            usage: ModelUsage(inputTokens: 5_000 * (idx + 1), outputTokens: 100)
        )
    }
}

// MARK: - Tests

struct CompactionTests {
    /// `usage.inputTokens` reported by the model wins over the heuristic
    /// estimator. As soon as it crosses the threshold, compaction triggers.
    @Test
    func compactionTriggersFromReportedUsage() async throws {
        let recorder = RequestRecorder()
        // Two scripted responses both report large input_tokens, well over
        // (modelContextWindow - reserveTokens) = 1024 default minimum.
        let scriptedModel = ScriptedModel(
            [
                ModelResponse(content: "first answer", usage: ModelUsage(inputTokens: 90_000)),
                ModelResponse(content: "second answer", usage: ModelUsage(inputTokens: 95_000)),
                ModelResponse(content: "third answer")
            ],
            recorder: recorder
        )
        let summarizer = ScriptedSummarizer(["## Goal\nbuild stuff\n## Next Steps\nfollow up"])

        let loop = AgentLoop(
            model: scriptedModel,
            summarizerModel: summarizer,
            config: AgentLoopConfig(
                maxSteps: 3,
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                compaction: CompactionConfig(
                    modelContextWindow: 100_000,
                    reserveTokens: 16_000,    // threshold = 84_000
                    keepRecentTokens: 1,       // cut everything back to the last user msg
                    minMessagesToCompact: 1
                )
            )
        )

        // Drive several turns. We can't easily get multiple steps from a single
        // run because the model has no tool calls. Instead, do three back-to-back
        // run() calls; each one is a full step that calls model.generate() once.
        _ = try await loop.run(userInput: "hello world")
        _ = try await loop.run(userInput: "another question")
        _ = try await loop.run(userInput: "third one please")

        // After at least one compaction, the request should contain a user msg
        // tagged "[Compaction summary".
        let captured = await recorder.all()
        let sawSummary = captured.contains { msgs in
            msgs.contains { $0.role == .user && $0.text.hasPrefix("[Compaction summary") }
        }
        #expect(sawSummary, "expected at least one request to include the compaction summary")
    }

    /// Without a reported usage we fall back to the estimator — so a
    /// conversation we know is small should NOT trigger compaction.
    @Test
    func smallConversationDoesNotTriggerCompaction() async throws {
        let recorder = RequestRecorder()
        let model = ScriptedModel(
            [ModelResponse(content: "ok")],
            recorder: recorder
        )
        let summarizer = ScriptedSummarizer(["should-not-be-called"])

        let loop = AgentLoop(
            model: model,
            summarizerModel: summarizer,
            config: AgentLoopConfig(
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                compaction: CompactionConfig() // defaults
            )
        )

        _ = try await loop.run(userInput: "hi")

        let captured = await recorder.all()
        let sawSummary = captured.contains { msgs in
            msgs.contains { $0.role == .user && $0.text.hasPrefix("[Compaction summary") }
        }
        #expect(!sawSummary)
    }

    /// The very first user message must always be in the request, even after
    /// the loop compacts away everything in between.
    @Test
    func firstUserMessageIsAnchoredAcrossCompaction() async throws {
        let recorder = RequestRecorder()
        let model = ScriptedModel(
            [
                ModelResponse(content: "a", usage: ModelUsage(inputTokens: 90_000)),
                ModelResponse(content: "b", usage: ModelUsage(inputTokens: 95_000)),
                ModelResponse(content: "c")
            ],
            recorder: recorder
        )
        let summarizer = ScriptedSummarizer([
            "## Goal\nthe goal\n## Next Steps\nnext"
        ])

        let loop = AgentLoop(
            model: model,
            summarizerModel: summarizer,
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

        // Every captured request must still contain the original goal.
        let all = await recorder.all()
        for msgs in all {
            let hasOriginal = msgs.contains { $0.role == .user && $0.text == originalGoal }
            #expect(hasOriginal, "first user message lost from request")
        }
    }

    /// Force-drop fallback: if the summariser keeps returning empty strings,
    /// the loop should eventually drop the oldest turn instead of looping.
    @Test
    func forceDropsAfterRepeatedSummarizerFailures() async throws {
        let recorder = RequestRecorder()
        // Each step crosses the threshold so the loop tries to compact after
        // every assistant message.
        let model = ScriptedModel(
            (0..<6).map { i in
                ModelResponse(content: "answer-\(i)", usage: ModelUsage(inputTokens: 90_000 + i))
            },
            recorder: recorder
        )
        // Summariser always returns "" → empty summary path → counted as failure.
        let summarizer = ScriptedSummarizer(["", "", "", "", "", ""])

        let loop = AgentLoop(
            model: model,
            summarizerModel: summarizer,
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

        // The fallback installs a placeholder summary. Look for our marker.
        let summary = await loop.currentCompactionSummary() ?? ""
        #expect(summary.contains("dropped after repeated summarisation failures"),
               "fallback placeholder not installed: \(summary)")
    }

    /// The cut point must land on a user message — never inside a tool turn,
    /// which would orphan a tool_use from its tool_result and crash the next
    /// model request.
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

        // Each turn does: assistant text + tool call + tool result + assistant
        // text. Compaction must not slice through that.
        let model = ScriptedModel(
            [
                // First user input: "tool turn one" — model emits a tool call,
                // then on the second step replies.
                ModelResponse(
                    content: "thinking",
                    toolCalls: [ToolCall(id: "1", name: "noop", argumentsJSON: "{}")],
                    usage: ModelUsage(inputTokens: 90_000)
                ),
                ModelResponse(content: "done one", usage: ModelUsage(inputTokens: 92_000)),
                // Second user input
                ModelResponse(
                    content: "thinking2",
                    toolCalls: [ToolCall(id: "2", name: "noop", argumentsJSON: "{}")],
                    usage: ModelUsage(inputTokens: 95_000)
                ),
                ModelResponse(content: "done two", usage: ModelUsage(inputTokens: 96_000)),
                // Third user input — by now compaction will have triggered at
                // least once. We rely on the cut having landed at a user
                // boundary; no broken tool pairs in the captured requests.
                ModelResponse(content: "done three"),
            ],
            recorder: recorder
        )
        let summarizer = ScriptedSummarizer([
            "## Progress\nstep 1 done", "## Progress\nstep 2 done"
        ])

        let loop = AgentLoop(
            model: model,
            summarizerModel: summarizer,
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

        // Verify every captured request: any assistant message with toolCalls
        // is followed (eventually) by a tool message with matching toolCallIDs
        // before the next user/system/end. Equivalently: we never see a tool
        // result in a request without a preceding assistant tool_use of the
        // same id.
        let all = await recorder.all()
        for msgs in all {
            var pendingToolUses = Set<String>()
            for msg in msgs {
                if msg.role == .assistant {
                    for call in msg.toolCalls { pendingToolUses.insert(call.id) }
                }
                if msg.role == .tool {
                    for result in msg.toolResults {
                        #expect(pendingToolUses.contains(result.toolCallID),
                               "tool_result \(result.toolCallID) without preceding tool_use")
                        pendingToolUses.remove(result.toolCallID)
                    }
                }
            }
            // Any pending tool_use without a tool_result is also broken.
            #expect(pendingToolUses.isEmpty,
                   "request ended with unresolved tool_use ids: \(pendingToolUses)")
        }
    }

    /// Prefer reported `usage` when present: if the model reports a tiny token
    /// count for a textually-large message, no compaction triggers — confirms
    /// the loop trusts usage over heuristic estimation.
    @Test
    func usageBeatsEstimator() async throws {
        let recorder = RequestRecorder()
        // The text would push the estimator above threshold, but reported
        // input_tokens stays low.
        let bigText = String(repeating: "x", count: 400_000) // ≈100k by char/4
        let model = ScriptedModel(
            [
                ModelResponse(content: bigText, usage: ModelUsage(inputTokens: 1_000)),
                ModelResponse(content: "more", usage: ModelUsage(inputTokens: 1_500))
            ],
            recorder: recorder
        )
        let summarizer = ScriptedSummarizer(["should-not-fire"])

        let loop = AgentLoop(
            model: model,
            summarizerModel: summarizer,
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
