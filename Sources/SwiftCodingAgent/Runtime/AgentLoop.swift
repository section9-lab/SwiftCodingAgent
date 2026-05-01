import Foundation

public struct AgentLoopConfig: Sendable {
    public let maxSteps: Int?
    public let workingDirectory: URL
    public let executionPolicy: ToolExecutionPolicy
    public let toolExecutionContexts: [String: ToolExecutionContext]
    public let compaction: CompactionConfig
    public let approvalHandler: ToolApprovalHandler?
    /// When true, tool calls returned in a single model turn run concurrently.
    /// Default `false` because not every tool is concurrency-safe (e.g. EditTool
    /// on the same file). Opt in once you know your tool set is safe.
    public let parallelToolCalls: Bool

    public var allowedRoots: [URL] {
        executionPolicy.fileAccess.allowedRoots
    }

    public init(
        maxSteps: Int? = 8,
        workingDirectory: URL,
        allowedRoots: [URL] = [],
        executionPolicy: ToolExecutionPolicy? = nil,
        toolExecutionContexts: [String: ToolExecutionContext] = [:],
        compaction: CompactionConfig = .init(),
        approvalHandler: ToolApprovalHandler? = nil,
        parallelToolCalls: Bool = false
    ) {
        self.maxSteps = maxSteps
        self.workingDirectory = workingDirectory
        let effectiveRoots = allowedRoots.isEmpty ? [workingDirectory] : allowedRoots
        self.executionPolicy = executionPolicy ?? ToolExecutionPolicy(
            allowedRoots: effectiveRoots
        )
        self.toolExecutionContexts = toolExecutionContexts
        self.compaction = compaction
        self.approvalHandler = approvalHandler
        self.parallelToolCalls = parallelToolCalls
    }

    public func context(for toolName: String) -> ToolExecutionContext {
        let context = toolExecutionContexts[toolName] ?? ToolExecutionContext(
            workingDirectory: workingDirectory,
            executionPolicy: executionPolicy
        )
        return context.withApprovalHandler(approvalHandler)
    }
}

public struct AgentRunResult: Sendable {
    public let finalText: String
    public let messages: [AgentMessage]
    public let steps: Int
    public let compactionSummary: String?

    public init(finalText: String, messages: [AgentMessage], steps: Int, compactionSummary: String?) {
        self.finalText = finalText
        self.messages = messages
        self.steps = steps
        self.compactionSummary = compactionSummary
    }
}

/// Events surfaced while `runStream` drives the agent loop.
///
/// The model's text response is streamed as it arrives; everything else (tool
/// invocations, results, step boundaries) is delivered as discrete events when
/// the corresponding work completes.
public enum AgentEvent: Sendable {
    /// A new step is starting (about to call the model). 1-indexed.
    case stepStarted(Int)
    /// Incremental assistant text from the current step. Concatenate to build
    /// the full text for that step.
    case textDelta(String)
    /// Incremental fragment of model "reasoning" / chain-of-thought (sourced
    /// from `reasoning_content` on OpenAI-style streams, or comparable
    /// channels on other providers). Forwarded as a separate event so callers
    /// can render it in a collapsed/dimmed pane without mixing it into the
    /// final answer. Reasoning is *not* persisted into the assistant message
    /// — it only exists during the live stream.
    case reasoningDelta(String)
    /// The assistant turn finished. `text` is the full assembled text for the
    /// step; `toolCalls` is empty if no tools were requested.
    case assistantTurn(text: String, toolCalls: [ToolCall])
    /// A tool is about to start executing.
    case toolStarted(ToolCall)
    /// A tool finished executing.
    case toolFinished(ToolResult)
    /// The agent loop has finished. Mirrors the result `run` returns.
    case completed(AgentRunResult)
}

public enum AgentLoopError: LocalizedError {
    case maxStepsReached

    public var errorDescription: String? {
        switch self {
        case .maxStepsReached:
            return "Agent loop reached max steps without final answer"
        }
    }
}

public actor AgentLoop {
    private struct CutPoint {
        let index: Int
    }

    private let model: any AgentModel
    /// Model used to summarise older history. Defaults to `model` if no
    /// dedicated summariser was provided (a smaller / cheaper model is often a
    /// good fit for this — see AgentSDK's `summarizerModel` parameter).
    private let summarizer: any AgentModel
    private let toolRegistry: ToolRegistry
    private let config: AgentLoopConfig
    private var messages: [AgentMessage]

    /// Messages in the [0..<immutablePrefixCount] range are never compacted
    /// and are sent verbatim on every request. Initially this covers skill
    /// system prompts; once the user sends their first message it grows to
    /// include that message too, so the original goal stays as an anchor.
    private var immutablePrefixCount: Int
    private var firstKeptMessageIndex: Int
    private var compactionSummary: String?
    private var firstUserMessageAnchored = false
    /// Last input-token count reported by the model. We trust this over any
    /// estimator: it's exact, post-cache, and matches what the provider bills.
    private var lastReportedInputTokens: Int?
    /// Counts consecutive failed compaction attempts. After enough failures
    /// we force-drop the oldest turn instead of looping forever.
    private var consecutiveCompactionFailures = 0

    public init(
        model: any AgentModel,
        summarizerModel: (any AgentModel)? = nil,
        skills: [any AgentSkill] = [],
        tools: [any AgentTool] = [],
        config: AgentLoopConfig
    ) {
        self.model = model
        self.summarizer = summarizerModel ?? model
        self.config = config

        let skillTools = skills.flatMap { $0.tools }
        self.toolRegistry = ToolRegistry(tools: tools + skillTools)

        var seedMessages: [AgentMessage] = []
        for skill in skills where !skill.systemPrompt.isEmpty {
            seedMessages.append(.system("[Skill: \(skill.name)]\n\(skill.systemPrompt)"))
        }

        self.messages = seedMessages
        self.immutablePrefixCount = seedMessages.count
        self.firstKeptMessageIndex = seedMessages.count
        self.compactionSummary = nil
    }

    public func history() -> [AgentMessage] {
        messages
    }

    public func currentCompactionSummary() -> String? {
        compactionSummary
    }

    /// Snapshot of how much of the model context window is currently in use,
    /// based on the same heuristic the auto-compactor uses.
    public func contextUsage() -> ContextUsage {
        let requestMessages = makeRequestMessages()
        let used = estimateTokens(messages: requestMessages)
        return ContextUsage(
            usedTokens: used,
            totalTokens: config.compaction.modelContextWindow,
            reservedTokens: config.compaction.reserveTokens
        )
    }

    @discardableResult
    public func run(userInput: String) async throws -> AgentRunResult {
        appendUserInput(userInput)

        var step = 0

        while config.maxSteps.map({ step < $0 }) ?? true {
            try Task.checkCancellation()
            step += 1

            try await maybeCompact()

            let request = ModelRequest(
                messages: makeRequestMessages(),
                tools: await makeRequestTools()
            )

            let response = try await model.generate(request: request)
            recordUsage(response.usage)

            // Persist the assistant turn as a single message carrying both the
            // textual response and any tool calls. This matches both OpenAI's
            // tool_calls array and Anthropic's tool_use blocks.
            if !response.content.isEmpty || !response.toolCalls.isEmpty {
                messages.append(
                    AgentMessage(
                        role: .assistant,
                        text: response.content,
                        toolCalls: response.toolCalls
                    )
                )
            }

            if response.toolCalls.isEmpty {
                return AgentRunResult(
                    finalText: response.content,
                    messages: messages,
                    steps: step,
                    compactionSummary: compactionSummary
                )
            }

            let results = try await runToolCalls(response.toolCalls)

            // Append all tool results in a single tool-role message so they
            // travel together, mirroring Anthropic's "tool_result blocks in one
            // user turn" expectation. The OpenAI adapter splits this back into
            // individual tool messages on the wire.
            messages.append(
                AgentMessage(role: .tool, toolResults: results)
            )
        }

        throw AgentLoopError.maxStepsReached
    }

    /// Streamed variant of `run`.
    ///
    /// AI text is delivered incrementally as `.textDelta` events while it
    /// arrives over the wire. Tool calls and tool results are delivered as
    /// complete units (no partial JSON) — tools themselves run in batches as
    /// before. Terminates with `.completed(AgentRunResult)` or by throwing.
    public nonisolated func runStream(userInput: String) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.driveStream(userInput: userInput, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func driveStream(
        userInput: String,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws {
        appendUserInput(userInput)

        var step = 0

        while config.maxSteps.map({ step < $0 }) ?? true {
            try Task.checkCancellation()
            step += 1
            continuation.yield(.stepStarted(step))

            try await maybeCompact()

            let request = ModelRequest(
                messages: makeRequestMessages(),
                tools: await makeRequestTools()
            )

            // Drive the model's stream and forward text deltas verbatim. Tool
            // calls are buffered by the adapter and arrive as whole objects.
            var stepText = ""
            var stepToolCalls: [ToolCall] = []

            for try await event in model.stream(request: request) {
                switch event {
                case .textDelta(let delta):
                    stepText += delta
                    continuation.yield(.textDelta(delta))
                case .reasoningDelta(let delta):
                    // Reasoning is forwarded but not folded into the
                    // persisted assistant message — it's transient UI state.
                    continuation.yield(.reasoningDelta(delta))
                case .toolCall(let call):
                    stepToolCalls.append(call)
                case .completed(let response):
                    // Adapters that fall back to non-streaming `generate` will
                    // surface text only here. Take whichever is non-empty.
                    if stepText.isEmpty { stepText = response.content }
                    if stepToolCalls.isEmpty { stepToolCalls = response.toolCalls }
                    recordUsage(response.usage)
                }
            }

            if !stepText.isEmpty || !stepToolCalls.isEmpty {
                messages.append(
                    AgentMessage(
                        role: .assistant,
                        text: stepText,
                        toolCalls: stepToolCalls
                    )
                )
            }
            continuation.yield(.assistantTurn(text: stepText, toolCalls: stepToolCalls))

            if stepToolCalls.isEmpty {
                let result = AgentRunResult(
                    finalText: stepText,
                    messages: messages,
                    steps: step,
                    compactionSummary: compactionSummary
                )
                continuation.yield(.completed(result))
                continuation.finish()
                return
            }

            // Announce + run tools in batch (mirrors `run`).
            for call in stepToolCalls { continuation.yield(.toolStarted(call)) }
            let results = try await runToolCalls(stepToolCalls)
            for result in results { continuation.yield(.toolFinished(result)) }

            messages.append(
                AgentMessage(role: .tool, toolResults: results)
            )
        }

        throw AgentLoopError.maxStepsReached
    }

    private func runToolCalls(_ calls: [ToolCall]) async throws -> [ToolResult] {
        if config.parallelToolCalls && calls.count > 1 {
            return try await withThrowingTaskGroup(of: (Int, ToolResult).self) { group in
                for (index, call) in calls.enumerated() {
                    let context = config.context(for: call.name)
                    let registry = toolRegistry
                    group.addTask {
                        let result = await Self.executeTool(
                            call: call,
                            context: context,
                            registry: registry
                        )
                        return (index, result)
                    }
                }

                var collected: [(Int, ToolResult)] = []
                for try await item in group {
                    collected.append(item)
                }
                return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
        }

        var results: [ToolResult] = []
        results.reserveCapacity(calls.count)
        for call in calls {
            let context = config.context(for: call.name)
            let result = await Self.executeTool(
                call: call,
                context: context,
                registry: toolRegistry
            )
            results.append(result)
        }
        return results
    }

    private static func executeTool(
        call: ToolCall,
        context: ToolExecutionContext,
        registry: ToolRegistry
    ) async -> ToolResult {
        do {
            let output = try await registry.run(call: call, context: context)
            return ToolResult(
                toolCallID: call.id,
                toolName: call.name,
                content: output,
                isError: false
            )
        } catch {
            return ToolResult(
                toolCallID: call.id,
                toolName: call.name,
                content: "ERROR: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    private func appendUserInput(_ text: String) {
        messages.append(.user(text))
        // Anchor the user's first message into the immutable prefix so the
        // original task description is never compacted away. This mirrors
        // pi-coding-agent's `firstKeptEntryId` anchor: subsequent compactions
        // operate strictly on messages after this point.
        if !firstUserMessageAnchored {
            firstUserMessageAnchored = true
            immutablePrefixCount = messages.count
            firstKeptMessageIndex = messages.count
        }
    }

    private func recordUsage(_ usage: ModelUsage?) {
        guard let usage, let input = usage.inputTokens else { return }
        lastReportedInputTokens = input
    }

    private func maybeCompact() async throws {
        _ = try await compactIfNeeded(force: false, customInstructions: nil)
    }

    public func compact(customInstructions: String? = nil) async throws -> String? {
        _ = try await compactIfNeeded(force: true, customInstructions: customInstructions)
        return compactionSummary
    }

    private func compactIfNeeded(force: Bool, customInstructions: String?) async throws -> Bool {
        let cfg = config.compaction
        guard cfg.enabled || force else { return false }

        if !force {
            let used = currentUsedTokens()
            let threshold = max(1_024, cfg.modelContextWindow - cfg.reserveTokens)
            guard used > threshold else { return false }
        }

        guard let cutPoint = findCutPoint(keepRecentTokens: cfg.keepRecentTokens),
              cutPoint.index > firstKeptMessageIndex,
              cutPoint.index - firstKeptMessageIndex >= cfg.minMessagesToCompact
        else {
            // No safe cut available — usually means the recent tail itself
            // exceeds keepRecentTokens. If repeated, force-drop the oldest
            // turn so the loop can make progress instead of hammering the
            // summariser indefinitely.
            return await registerCompactionFailure(reason: .noCutPoint)
        }

        let toSummarize = Array(messages[firstKeptMessageIndex..<cutPoint.index])
        let serialized = serializeForSummary(messages: toSummarize)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !serialized.isEmpty else {
            return await registerCompactionFailure(reason: .emptyContent)
        }

        let summaryPrompt = makeCompactionPrompt(
            serializedConversation: serialized,
            customInstructions: customInstructions
        )

        let newSummary: String
        do {
            let result = try await summarizer.generate(
                request: ModelRequest(
                    messages: [.user(summaryPrompt)],
                    tools: []
                )
            )
            newSummary = result.content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } catch {
            return await registerCompactionFailure(reason: .summarizerError)
        }

        guard !newSummary.isEmpty else {
            return await registerCompactionFailure(reason: .emptySummary)
        }

        // Merge with the previous summary. If the combined length blows past
        // the configured threshold, ask the summariser to consolidate the two
        // into a single tighter summary instead of doing a character-suffix
        // truncate (which would silently lose the older anchor).
        let consolidated = try await consolidateSummaryIfNeeded(
            old: compactionSummary,
            new: newSummary,
            threshold: cfg.summaryConsolidateThreshold
        )

        compactionSummary = consolidated
        firstKeptMessageIndex = cutPoint.index
        consecutiveCompactionFailures = 0
        return true
    }

    private enum CompactionFailureReason {
        case noCutPoint, emptyContent, emptySummary, summarizerError
    }

    /// Track repeated compaction failures and, after enough of them, drop the
    /// oldest turn with a placeholder so the conversation can keep moving.
    private func registerCompactionFailure(reason: CompactionFailureReason) async -> Bool {
        consecutiveCompactionFailures += 1
        guard consecutiveCompactionFailures >= config.compaction.maxConsecutiveFailures else {
            return false
        }

        // Find the next turn boundary after firstKeptMessageIndex and discard
        // everything up to it, replacing with a synthetic placeholder.
        let dropTarget = nextTurnBoundary(after: firstKeptMessageIndex)
        guard let dropTo = dropTarget, dropTo > firstKeptMessageIndex else {
            // Nothing safe to drop. Reset counter so we don't spin.
            consecutiveCompactionFailures = 0
            return false
        }

        let droppedCount = dropTo - firstKeptMessageIndex
        let placeholder = "[\(droppedCount) earlier message\(droppedCount == 1 ? "" : "s") dropped after repeated summarisation failures]"
        compactionSummary = compactionSummary.map { $0 + "\n\n" + placeholder } ?? placeholder
        firstKeptMessageIndex = dropTo
        consecutiveCompactionFailures = 0
        return true
    }

    /// First user-message index strictly greater than `start`. Used as a safe
    /// drop target — guarantees we never split a tool_use / tool_result pair.
    private func nextTurnBoundary(after start: Int) -> Int? {
        var i = start + 1
        while i < messages.count {
            if messages[i].role == .user { return i }
            i += 1
        }
        return nil
    }

    private func consolidateSummaryIfNeeded(
        old: String?,
        new: String,
        threshold: Int
    ) async throws -> String {
        let merged = old.map { $0 + "\n\n---\n\n" + new } ?? new
        if merged.count <= threshold { return merged }

        // Ask the summariser to fold both into one tighter summary, preserving
        // the anchor / goal / decisions explicitly. If this call fails we keep
        // the merged form (truncating from the end as a last resort).
        let prompt = """
        You are consolidating two compaction summaries into one tighter summary that fits future model contexts.

        Preserve every concrete fact: goal, constraints, file paths, decisions made, errors, and next steps. Drop only redundancy. Keep the same section headers as in the inputs (## Goal, ## Constraints & Preferences, ## Progress, ## Key Decisions, ## Next Steps, ## Critical Context).

        Older summary:
        \(old ?? "(none)")

        Newer summary:
        \(new)
        """
        do {
            let result = try await summarizer.generate(
                request: ModelRequest(messages: [.user(prompt)], tools: [])
            )
            let consolidated = result.content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !consolidated.isEmpty { return consolidated }
        } catch {
            // Fall through to fallback truncate.
        }

        // Fallback: keep the start of the merged summary (which contains the
        // older anchors) plus the very end (most recent), explicitly marking
        // the gap. This is a degraded but honest result.
        if merged.count <= threshold { return merged }
        let head = String(merged.prefix(threshold / 2))
        let tail = String(merged.suffix(threshold / 2))
        return head + "\n\n[…consolidation failed; some intermediate summary detail elided…]\n\n" + tail
    }

    private func makeCompactionPrompt(
        serializedConversation: String,
        customInstructions: String?
    ) -> String {
        config.compaction.promptBuilder(
            CompactionPromptInput(
                serializedConversation: serializedConversation,
                previousSummary: compactionSummary,
                customInstructions: customInstructions,
                isSplitTurn: false
            )
        )
    }

    private func makeRequestMessages() -> [AgentMessage] {
        var requestMessages: [AgentMessage] = []

        if immutablePrefixCount > 0 {
            requestMessages.append(contentsOf: messages.prefix(immutablePrefixCount))
        }

        // Inject the summary as a `user` message rather than `system`. Pi-style.
        // Anthropic concatenates all `system` content into the top-level system
        // field, which would conflate the summary with the actual system prompt
        // and may change model behaviour. A user-role wrapper avoids that.
        if let compactionSummary,
           !compactionSummary.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
        {
            requestMessages.append(
                .user("[Compaction summary of earlier conversation]\n\n\(compactionSummary)")
            )
        }

        if firstKeptMessageIndex < messages.count {
            requestMessages.append(contentsOf: messages[firstKeptMessageIndex...])
        }

        return requestMessages
    }

    private func makeRequestTools() async -> [ModelToolSpec] {
        await toolRegistry.allSpecs().sorted { $0.name < $1.name }
    }

    /// Total token weight of a single message, counting every payload field.
    /// Used by both the trigger check and the cut-point search so the two
    /// agree on how big the conversation is.
    private func messageWeight(_ message: AgentMessage) -> Int {
        var size = TokenEstimator.estimate(message.text)
        for call in message.toolCalls {
            size += TokenEstimator.estimate(call.argumentsJSON)
        }
        for result in message.toolResults {
            size += TokenEstimator.estimate(result.content)
        }
        return size + 12  // envelope estimate
    }

    private func estimateTokens(messages: [AgentMessage]) -> Int {
        messages.reduce(0) { $0 + messageWeight($1) }
    }

    /// Tokens currently being sent to the model. Prefer the model's own usage
    /// reporting (exact, post-cache) over our heuristic when available.
    private func currentUsedTokens() -> Int {
        if let reported = lastReportedInputTokens { return reported }
        return estimateTokens(messages: makeRequestMessages())
    }

    /// Cut points are strictly at user-message boundaries. We never split a
    /// turn (which would orphan a `tool_use` from its `tool_result` and crash
    /// the next request). If no boundary lies between the immutable prefix
    /// and the recent tail, we return nil and the caller falls back to the
    /// failure path.
    private func findCutPoint(keepRecentTokens: Int) -> CutPoint? {
        guard firstKeptMessageIndex < messages.count else { return nil }

        // Walk backwards summing message weight until we have enough recent
        // history pinned. The cut point is everything older than this.
        var acc = 0
        var idx = messages.count - 1
        while idx >= firstKeptMessageIndex {
            acc += messageWeight(messages[idx])
            if acc >= keepRecentTokens { break }
            idx -= 1
        }

        // Snap the cut to the nearest user-message boundary at or before idx.
        var candidate = idx
        while candidate > firstKeptMessageIndex, messages[candidate].role != .user {
            candidate -= 1
        }

        guard candidate > firstKeptMessageIndex,
              messages[candidate].role == .user
        else {
            return nil
        }

        return CutPoint(index: candidate)
    }

    private func serializeForSummary(messages: [AgentMessage]) -> String {
        messages.map { message in
            switch message.role {
            case .system:
                return "[System] \(message.text)"
            case .user:
                return "[User] \(message.text)"
            case .assistant:
                var parts: [String] = []
                if !message.text.isEmpty {
                    parts.append("[Assistant] \(message.text)")
                }
                for call in message.toolCalls {
                    parts.append("[Assistant ToolCall: \(call.name)] args=\(call.argumentsJSON)")
                }
                return parts.joined(separator: "\n")
            case .tool:
                let maxLen = 4_000
                return message.toolResults.map { result in
                    let truncated = result.content.count > maxLen
                        ? String(result.content.prefix(maxLen)) + " ...(truncated \(result.content.count - maxLen) chars)"
                        : result.content
                    return "[Tool Result: \(result.toolName)] \(truncated)"
                }.joined(separator: "\n")
            }
        }
        .joined(separator: "\n")
    }
}
