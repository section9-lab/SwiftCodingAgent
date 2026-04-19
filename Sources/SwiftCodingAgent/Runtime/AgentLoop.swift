import Foundation

public struct AgentLoopConfig: Sendable {
    public let maxSteps: Int
    public let workingDirectory: URL
    public let executionPolicy: ToolExecutionPolicy
    public let toolExecutionContexts: [String: ToolExecutionContext]
    public let compaction: CompactionConfig

    public var allowedRoots: [URL] {
        executionPolicy.fileAccess.allowedRoots
    }

    public init(
        maxSteps: Int = 8,
        workingDirectory: URL,
        allowedRoots: [URL] = [],
        executionPolicy: ToolExecutionPolicy? = nil,
        toolExecutionContexts: [String: ToolExecutionContext] = [:],
        compaction: CompactionConfig = .init()
    ) {
        self.maxSteps = maxSteps
        self.workingDirectory = workingDirectory
        let effectiveRoots = allowedRoots.isEmpty ? [workingDirectory] : allowedRoots
        self.executionPolicy = executionPolicy ?? ToolExecutionPolicy(
            allowedRoots: effectiveRoots
        )
        self.toolExecutionContexts = toolExecutionContexts
        self.compaction = compaction
    }

    public func context(for toolName: String) -> ToolExecutionContext {
        toolExecutionContexts[toolName] ?? ToolExecutionContext(
            workingDirectory: workingDirectory,
            executionPolicy: executionPolicy
        )
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
            seedMessages.append(AgentMessage(role: .system, content: "[Skill: \(skill.name)]\n\(skill.systemPrompt)"))
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

    @discardableResult
    public func run(userInput: String) async throws -> AgentRunResult {
        messages.append(AgentMessage(role: .user, content: userInput))

        for step in 1...config.maxSteps {
            try await maybeCompact()

            let request = ModelRequest(
                messages: makeRequestMessages(),
                tools: await makeRequestTools()
            )

            let response = try await model.generate(request: request)

            if !response.content.isEmpty {
                messages.append(AgentMessage(role: .assistant, content: response.content))
            }

            if response.toolCalls.isEmpty {
                return AgentRunResult(
                    finalText: response.content,
                    messages: messages,
                    steps: step,
                    compactionSummary: compactionSummary
                )
            }

            for call in response.toolCalls {
                let context = config.context(for: call.name)
                messages.append(
                    AgentMessage(
                        role: .assistant,
                        content: "",
                        toolName: call.name,
                        toolCallID: call.id,
                        toolArgumentsJSON: call.argumentsJSON
                    )
                )

                do {
                    let output = try await toolRegistry.run(call: call, context: context)

                    messages.append(
                        AgentMessage(
                            role: .tool,
                            content: output,
                            toolName: call.name,
                            toolCallID: call.id
                        )
                    )
                } catch {
                    messages.append(
                        AgentMessage(
                            role: .tool,
                            content: "ERROR: \(error.localizedDescription)",
                            toolName: call.name,
                            toolCallID: call.id
                        )
                    )
                }
            }
        }

        throw AgentLoopError.maxStepsReached
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
                messages: [AgentMessage(role: .user, content: summaryPrompt)],
                tools: []
            )
        )

        let newSummary = result.content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !newSummary.isEmpty else { return false }

        compactionSummary = mergeSummary(old: compactionSummary, new: newSummary, maxChars: cfg.maxSummaryChars)
        firstKeptMessageIndex = cutPoint.index
        return true
    }

    private func makeCompactionPrompt(
        serializedConversation: String,
        customInstructions: String?,
        isSplitTurn: Bool
    ) -> String {
        let previousSummarySection: String
        if let compactionSummary, !compactionSummary.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            previousSummarySection = """
            [已有压缩摘要]
            \(compactionSummary)

            """
        } else {
            previousSummarySection = ""
        }

        let customSection: String
        if let customInstructions, !customInstructions.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            customSection = """
            [额外要求]
            \(customInstructions.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))

            """
        } else {
            customSection = ""
        }

        let splitTurnSection: String
        if isSplitTurn {
            splitTurnSection = """
            [注意]
            当前发生 split-turn：被压缩内容是某个超长 turn 的前半段，请明确保留该 turn 的关键中间状态与未完成事项。

            """
        } else {
            splitTurnSection = ""
        }

        return """
        你是会话压缩器。请把下面的历史压缩为结构化摘要，必须忠实，不得臆造。

        输出格式：
        ## Goal
        ## Constraints & Preferences
        ## Progress
        ### Done
        ### In Progress
        ### Blocked
        ## Key Decisions
        ## Next Steps
        ## Critical Context

        要求：
        - 保留用户明确约束、技术决策、失败原因、下一步
        - 保留关键文件路径、命令结论、错误信息
        - 不要输出与上下文无关的内容

        \(customSection)\(splitTurnSection)\(previousSummarySection)[待压缩会话]
        \(serializedConversation)
        """
    }

    private func makeRequestMessages() -> [AgentMessage] {
        var requestMessages: [AgentMessage] = []

        if immutablePrefixCount > 0 {
            requestMessages.append(contentsOf: messages.prefix(immutablePrefixCount))
        }

        if let compactionSummary,
           !compactionSummary.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
        {
            requestMessages.append(
                AgentMessage(
                    role: .system,
                    content: "[Compaction Summary]\n\(compactionSummary)"
                )
            )
        }

        if firstKeptMessageIndex < messages.count {
            requestMessages.append(contentsOf: messages[firstKeptMessageIndex...])
        }

        return requestMessages.filter { !($0.role == .assistant && $0.toolName != nil) }
    }

    private func makeRequestTools() async -> [ModelToolSpec] {
        await toolRegistry.allSpecs().sorted { $0.name < $1.name }
    }

    private func estimateTokens(messages: [AgentMessage]) -> Int {
        messages.reduce(0) { partial, message in
            partial + TokenEstimator.estimate(message.content) + TokenEstimator.estimate(message.toolArgumentsJSON ?? "") + 12
        }
    }

    private func findCutPoint(keepRecentTokens: Int) -> CutPoint? {
        guard firstKeptMessageIndex < messages.count else { return nil }

        var acc = 0
        var idx = messages.count - 1

        while idx >= firstKeptMessageIndex {
            acc += TokenEstimator.estimate(messages[idx].content) + 12
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
                return "[System] \(message.content)"
            case .user:
                return "[User] \(message.content)"
            case .assistant:
                if let toolName = message.toolName {
                    return "[Assistant ToolCall: \(toolName)] args=\(message.toolArgumentsJSON ?? "")"
                }
                return "[Assistant] \(message.content)"
            case .tool:
                let maxLen = 2_000
                let toolOutput = message.content.count > maxLen
                    ? String(message.content.prefix(maxLen)) + " ...(truncated \(message.content.count - maxLen) chars)"
                    : message.content
                return "[Tool Result: \(message.toolName ?? "unknown")] \(toolOutput)"
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
