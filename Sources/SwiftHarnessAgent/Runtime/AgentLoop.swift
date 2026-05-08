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
    public let messages: [LLMMessage]
    public let steps: Int
    public let compactionSummary: String?

    public init(finalText: String, messages: [LLMMessage], steps: Int, compactionSummary: String?) {
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
    /// Incremental assistant text from the current step.
    case textDelta(String)
    /// Incremental fragment of model "reasoning" / chain-of-thought. Forwarded
    /// as a separate event so callers can render it in a collapsed/dimmed
    /// pane without mixing it into the final answer. Reasoning blocks WITH
    /// signatures are persisted into the assistant message (required for
    /// Anthropic extended-thinking + tool-use multi-turn correctness);
    /// reasoning without a signature is transient UI state only.
    case reasoningDelta(String)
    /// The assistant turn finished. `text` is the full assembled text for the
    /// step; `toolUses` is empty if no tools were requested.
    case assistantTurn(text: String, toolUses: [LLMToolUse])
    /// A tool is about to start executing.
    case toolStarted(LLMToolUse)
    /// A tool finished executing.
    case toolFinished(LLMToolResult)
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

    private let client: any LLMClient
    private let modelName: String
    /// Client used to summarise older history. Defaults to `client` if no
    /// dedicated summariser was provided.
    private let summarizer: any LLMClient
    private let summarizerModelName: String
    private let toolRegistry: ToolRegistry
    private let config: AgentLoopConfig
    private var messages: [LLMMessage]

    /// Messages in the [0..<immutablePrefixCount] range are never compacted
    /// and are sent verbatim on every request. Initially this covers skill
    /// system prompts; once the user sends their first message it grows to
    /// include that message too, so the original goal stays as an anchor.
    private var immutablePrefixCount: Int
    private var firstKeptMessageIndex: Int
    private var compactionSummary: String?
    private var firstUserMessageAnchored = false
    /// Last input-token count reported by the model.
    private var lastReportedInputTokens: Int?
    /// Counts consecutive failed compaction attempts.
    private var consecutiveCompactionFailures = 0

    public init(
        client: any LLMClient,
        modelName: String,
        summarizer: (any LLMClient)? = nil,
        summarizerModelName: String? = nil,
        skills: [any AgentSkill] = [],
        tools: [any AgentTool] = [],
        config: AgentLoopConfig
    ) {
        self.client = client
        self.modelName = modelName
        self.summarizer = summarizer ?? client
        self.summarizerModelName = summarizerModelName ?? modelName
        self.config = config

        let skillTools = skills.flatMap { $0.tools }
        self.toolRegistry = ToolRegistry(tools: tools + skillTools)

        var seedMessages: [LLMMessage] = []
        for skill in skills where !skill.systemPrompt.isEmpty {
            seedMessages.append(.system("[Skill: \(skill.name)]\n\(skill.systemPrompt)"))
        }

        self.messages = seedMessages
        self.immutablePrefixCount = seedMessages.count
        self.firstKeptMessageIndex = seedMessages.count
        self.compactionSummary = nil
    }

    public func history() -> [LLMMessage] {
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

            let request = LLMRequest(
                model: modelName,
                messages: makeRequestMessages(),
                tools: await makeRequestTools()
            )

            let response = try await client.complete(request)
            recordUsage(response.usage)

            // Persist the assistant turn verbatim — including any reasoning
            // blocks with signatures (required for Anthropic extended-thinking
            // + tool_use multi-turn correctness).
            if !response.message.content.isEmpty {
                messages.append(response.message)
            }

            let toolUses = response.message.toolUses

            if toolUses.isEmpty {
                return AgentRunResult(
                    finalText: response.message.text,
                    messages: messages,
                    steps: step,
                    compactionSummary: compactionSummary
                )
            }

            let results = try await runToolCalls(toolUses)

            // Append all tool results in a single tool-role message so they
            // travel together, mirroring Anthropic's "tool_result blocks in one
            // user turn" expectation. The OpenAI adapters split this back into
            // individual items on the wire.
            messages.append(LLMMessage(
                role: .tool,
                content: results.map { LLMContentBlock.toolResult($0) }
            ))
        }

        throw AgentLoopError.maxStepsReached
    }

    /// Streamed variant of `run`.
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

            let request = LLMRequest(
                model: modelName,
                messages: makeRequestMessages(),
                tools: await makeRequestTools()
            )

            // Drive the model's stream. Forward text + reasoning deltas
            // verbatim; assemble the final message from the messageStop event.
            var stepMessage: LLMMessage?
            var stepText = ""
            var stepToolUses: [LLMToolUse] = []

            for try await event in client.stream(request) {
                switch event {
                case .messageStart, .blockStart, .blockStop:
                    break
                case .textDelta(let delta):
                    continuation.yield(.textDelta(delta))
                case .reasoningDelta(let payload):
                    continuation.yield(.reasoningDelta(payload.delta))
                case .toolArgumentsDelta:
                    // Suppressed at this layer — we expose tool_use as a
                    // single event when the call is complete.
                    break
                case .messageStop(let response):
                    stepMessage = response.message
                    stepText = response.message.text
                    stepToolUses = response.message.toolUses
                    recordUsage(response.usage)
                }
            }

            if let stepMessage, !stepMessage.content.isEmpty {
                messages.append(stepMessage)
            }
            continuation.yield(.assistantTurn(text: stepText, toolUses: stepToolUses))

            if stepToolUses.isEmpty {
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

            for use in stepToolUses { continuation.yield(.toolStarted(use)) }
            let results = try await runToolCalls(stepToolUses)
            for result in results { continuation.yield(.toolFinished(result)) }

            messages.append(LLMMessage(
                role: .tool,
                content: results.map { LLMContentBlock.toolResult($0) }
            ))
        }

        throw AgentLoopError.maxStepsReached
    }

    /// Schedule tool calls according to each tool's `concurrency` declaration.
    ///
    /// When `parallelToolCalls` is enabled, this implements an oh-my-pi-style
    /// barrier scheduler:
    /// - `.shared` tools accumulate into a batch and run concurrently.
    /// - `.exclusive` tools act as barriers: the pending shared batch drains
    ///   first, then the exclusive tool runs alone, then accumulation resumes.
    ///
    /// Results are returned in the original `uses` order regardless of the
    /// completion order, so the assistant message stays consistent with the
    /// model's tool_use sequence.
    ///
    /// When `parallelToolCalls` is disabled (the default for backward
    /// compatibility), all tools run strictly sequentially.
    internal func runToolCalls(_ uses: [LLMToolUse]) async throws -> [LLMToolResult] {
        guard config.parallelToolCalls && uses.count > 1 else {
            return try await runSequentially(uses)
        }

        // Resolve concurrency for every call up front. Unknown tools default
        // to `.shared` — the actual error surfaces inside `executeTool` when
        // the registry lookup fails.
        var concurrencies: [ToolConcurrency] = []
        concurrencies.reserveCapacity(uses.count)
        for use in uses {
            concurrencies.append(await toolRegistry.concurrency(for: use.name))
        }

        var results: [LLMToolResult?] = Array(repeating: nil, count: uses.count)
        var sharedBatch: [(Int, LLMToolUse)] = []

        func drainSharedBatch() async {
            guard !sharedBatch.isEmpty else { return }
            let batch = sharedBatch
            sharedBatch.removeAll(keepingCapacity: true)
            let registry = toolRegistry
            let cfg = config
            await withTaskGroup(of: (Int, LLMToolResult).self) { group in
                for (index, use) in batch {
                    let context = cfg.context(for: use.name)
                    group.addTask {
                        let result = await Self.executeTool(
                            use: use,
                            context: context,
                            registry: registry
                        )
                        return (index, result)
                    }
                }
                for await (index, result) in group {
                    results[index] = result
                }
            }
        }

        for (index, use) in uses.enumerated() {
            try Task.checkCancellation()
            switch concurrencies[index] {
            case .shared:
                sharedBatch.append((index, use))
            case .exclusive:
                await drainSharedBatch()
                let context = config.context(for: use.name)
                let result = await Self.executeTool(
                    use: use,
                    context: context,
                    registry: toolRegistry
                )
                results[index] = result
            }
        }
        await drainSharedBatch()

        // Every slot must be filled by construction; force-unwrap surfaces a
        // scheduler bug rather than papering over it.
        return results.map { $0! }
    }

    private func runSequentially(_ uses: [LLMToolUse]) async throws -> [LLMToolResult] {
        var results: [LLMToolResult] = []
        results.reserveCapacity(uses.count)
        for use in uses {
            try Task.checkCancellation()
            let context = config.context(for: use.name)
            let result = await Self.executeTool(
                use: use,
                context: context,
                registry: toolRegistry
            )
            results.append(result)
        }
        return results
    }

    private static func executeTool(
        use: LLMToolUse,
        context: ToolExecutionContext,
        registry: ToolRegistry
    ) async -> LLMToolResult {
        do {
            let output = try await registry.run(use: use, context: context)
            return LLMToolResult(
                toolUseID: use.id,
                toolName: use.name,
                content: output,
                isError: false
            )
        } catch {
            return LLMToolResult(
                toolUseID: use.id,
                toolName: use.name,
                content: "ERROR: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    private func appendUserInput(_ text: String) {
        messages.append(.user(text))
        if !firstUserMessageAnchored {
            firstUserMessageAnchored = true
            immutablePrefixCount = messages.count
            firstKeptMessageIndex = messages.count
        }
    }

    private func recordUsage(_ usage: LLMUsage?) {
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
            let result = try await summarizer.complete(
                LLMRequest(
                    model: summarizerModelName,
                    messages: [.user(summaryPrompt)],
                    tools: []
                )
            )
            newSummary = result.message.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } catch {
            return await registerCompactionFailure(reason: .summarizerError)
        }

        guard !newSummary.isEmpty else {
            return await registerCompactionFailure(reason: .emptySummary)
        }

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

    private func registerCompactionFailure(reason: CompactionFailureReason) async -> Bool {
        consecutiveCompactionFailures += 1
        guard consecutiveCompactionFailures >= config.compaction.maxConsecutiveFailures else {
            return false
        }

        let dropTarget = nextTurnBoundary(after: firstKeptMessageIndex)
        guard let dropTo = dropTarget, dropTo > firstKeptMessageIndex else {
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

        let prompt = """
        You are consolidating two compaction summaries into one tighter summary that fits future model contexts.

        Preserve every concrete fact: goal, constraints, file paths, decisions made, errors, and next steps. Drop only redundancy. Keep the same section headers as in the inputs (## Goal, ## Constraints & Preferences, ## Progress, ## Key Decisions, ## Next Steps, ## Critical Context).

        Older summary:
        \(old ?? "(none)")

        Newer summary:
        \(new)
        """
        do {
            let result = try await summarizer.complete(
                LLMRequest(
                    model: summarizerModelName,
                    messages: [.user(prompt)],
                    tools: []
                )
            )
            let consolidated = result.message.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !consolidated.isEmpty { return consolidated }
        } catch {
            // Fall through to fallback truncate.
        }

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

    private func makeRequestMessages() -> [LLMMessage] {
        var requestMessages: [LLMMessage] = []

        if immutablePrefixCount > 0 {
            requestMessages.append(contentsOf: messages.prefix(immutablePrefixCount))
        }

        // Inject the summary as a `user` message rather than `system` so it
        // doesn't get conflated with the actual system prompt by providers
        // that concatenate all system content into one top-level field
        // (Anthropic).
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

    private func makeRequestTools() async -> [LLMToolSpec] {
        await toolRegistry.allSpecs().sorted { $0.name < $1.name }
    }

    /// Total token weight of a single message, counting every payload field.
    private func messageWeight(_ message: LLMMessage) -> Int {
        var size = 0
        for block in message.content {
            switch block {
            case .text(let s):
                size += TokenEstimator.estimate(s)
            case .reasoning(let r):
                size += TokenEstimator.estimate(r.text)
                if let sig = r.signature { size += TokenEstimator.estimate(sig) }
                if let enc = r.encryptedContent { size += TokenEstimator.estimate(enc) }
            case .toolUse(let use):
                size += TokenEstimator.estimate(use.argumentsJSON)
                size += TokenEstimator.estimate(use.name)
            case .toolResult(let result):
                size += TokenEstimator.estimate(result.content)
            case .image:
                size += 256 // rough: image block uses a fixed slot in most providers
            case .refusal(let s):
                size += TokenEstimator.estimate(s)
            }
        }
        return size + 12  // envelope estimate
    }

    private func estimateTokens(messages: [LLMMessage]) -> Int {
        messages.reduce(0) { $0 + messageWeight($1) }
    }

    private func currentUsedTokens() -> Int {
        if let reported = lastReportedInputTokens { return reported }
        return estimateTokens(messages: makeRequestMessages())
    }

    private func findCutPoint(keepRecentTokens: Int) -> CutPoint? {
        guard firstKeptMessageIndex < messages.count else { return nil }

        var acc = 0
        var idx = messages.count - 1
        while idx >= firstKeptMessageIndex {
            acc += messageWeight(messages[idx])
            if acc >= keepRecentTokens { break }
            idx -= 1
        }

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

    private func serializeForSummary(messages: [LLMMessage]) -> String {
        messages.map { message in
            switch message.role {
            case .system:
                return "[System] \(message.text)"
            case .user:
                return "[User] \(message.text)"
            case .assistant:
                var parts: [String] = []
                let text = message.text
                if !text.isEmpty {
                    parts.append("[Assistant] \(text)")
                }
                for use in message.toolUses {
                    parts.append("[Assistant ToolCall: \(use.name)] args=\(use.argumentsJSON)")
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
