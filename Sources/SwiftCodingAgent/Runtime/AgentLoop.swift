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
        let isSplitTurn: Bool
    }

    private let model: any AgentModel
    private let toolRegistry: ToolRegistry
    private let config: AgentLoopConfig
    private var messages: [AgentMessage]

    private let immutablePrefixCount: Int
    private var firstKeptMessageIndex: Int
    private var compactionSummary: String?

    public init(
        model: any AgentModel,
        skills: [any AgentSkill] = [],
        tools: [any AgentTool] = [],
        config: AgentLoopConfig
    ) {
        self.model = model
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
        messages.append(.user(userInput))

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
            let requestMessages = makeRequestMessages()
            let estimatedTokens = estimateTokens(messages: requestMessages)
            let threshold = max(1_024, cfg.modelContextWindow - cfg.reserveTokens)
            guard estimatedTokens > threshold else { return false }
        }

        guard let cutPoint = findCutPoint(keepRecentTokens: cfg.keepRecentTokens),
              cutPoint.index > firstKeptMessageIndex,
              cutPoint.index - firstKeptMessageIndex >= cfg.minMessagesToCompact
        else {
            return false
        }

        let toSummarize = Array(messages[firstKeptMessageIndex..<cutPoint.index])
        let serialized = serializeForSummary(messages: toSummarize)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !serialized.isEmpty else { return false }

        let summaryPrompt = makeCompactionPrompt(
            serializedConversation: serialized,
            customInstructions: customInstructions,
            isSplitTurn: cutPoint.isSplitTurn
        )
        let result = try await model.generate(
            request: ModelRequest(
                messages: [.user(summaryPrompt)],
                tools: []
            )
        )

        let newSummary = result.content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !newSummary.isEmpty else { return false }

        // Compute the merged summary first, then commit both pieces of state
        // together so a failure can't leave history pruned without a summary.
        let merged = mergeSummary(old: compactionSummary, new: newSummary, maxChars: cfg.maxSummaryChars)
        compactionSummary = merged
        firstKeptMessageIndex = cutPoint.index
        return true
    }

    private func makeCompactionPrompt(
        serializedConversation: String,
        customInstructions: String?,
        isSplitTurn: Bool
    ) -> String {
        config.compaction.promptBuilder(
            CompactionPromptInput(
                serializedConversation: serializedConversation,
                previousSummary: compactionSummary,
                customInstructions: customInstructions,
                isSplitTurn: isSplitTurn
            )
        )
    }

    private func makeRequestMessages() -> [AgentMessage] {
        var requestMessages: [AgentMessage] = []

        if immutablePrefixCount > 0 {
            requestMessages.append(contentsOf: messages.prefix(immutablePrefixCount))
        }

        if let compactionSummary,
           !compactionSummary.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
        {
            requestMessages.append(.system("[Compaction Summary]\n\(compactionSummary)"))
        }

        if firstKeptMessageIndex < messages.count {
            requestMessages.append(contentsOf: messages[firstKeptMessageIndex...])
        }

        return requestMessages
    }

    private func makeRequestTools() async -> [ModelToolSpec] {
        await toolRegistry.allSpecs().sorted { $0.name < $1.name }
    }

    private func estimateTokens(messages: [AgentMessage]) -> Int {
        messages.reduce(0) { partial, message in
            var size = TokenEstimator.estimate(message.text)
            for call in message.toolCalls {
                size += TokenEstimator.estimate(call.argumentsJSON)
            }
            for result in message.toolResults {
                size += TokenEstimator.estimate(result.content)
            }
            return partial + size + 12
        }
    }

    private func findCutPoint(keepRecentTokens: Int) -> CutPoint? {
        guard firstKeptMessageIndex < messages.count else { return nil }

        var acc = 0
        var idx = messages.count - 1

        while idx >= firstKeptMessageIndex {
            acc += TokenEstimator.estimate(messages[idx].text) + 12
            if acc >= keepRecentTokens {
                break
            }
            idx -= 1
        }

        guard idx > firstKeptMessageIndex else { return nil }

        var candidate = idx
        while candidate > firstKeptMessageIndex, !isValidCutPoint(messages[candidate]) {
            candidate -= 1
        }

        guard candidate > firstKeptMessageIndex else { return nil }

        var cut = candidate
        while cut > firstKeptMessageIndex {
            if messages[cut].role == .user {
                return CutPoint(index: cut, isSplitTurn: false)
            }
            cut -= 1
        }

        return CutPoint(index: candidate, isSplitTurn: true)
    }

    private func isValidCutPoint(_ message: AgentMessage) -> Bool {
        switch message.role {
        case .user, .assistant:
            return true
        case .tool, .system:
            return false
        }
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
                let maxLen = 2_000
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

    private func mergeSummary(old: String?, new: String, maxChars: Int) -> String {
        let merged = old.map { $0 + "\n\n---\n\n" + new } ?? new
        if merged.count <= maxChars { return merged }
        return String(merged.suffix(maxChars))
    }
}
