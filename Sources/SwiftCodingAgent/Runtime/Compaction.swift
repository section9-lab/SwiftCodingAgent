import Foundation

public struct CompactionPromptInput: Sendable {
    public let serializedConversation: String
    public let previousSummary: String?
    public let customInstructions: String?
    public let isSplitTurn: Bool

    public init(
        serializedConversation: String,
        previousSummary: String?,
        customInstructions: String?,
        isSplitTurn: Bool
    ) {
        self.serializedConversation = serializedConversation
        self.previousSummary = previousSummary
        self.customInstructions = customInstructions
        self.isSplitTurn = isSplitTurn
    }
}

public typealias CompactionPromptBuilder = @Sendable (CompactionPromptInput) -> String

public struct CompactionConfig: Sendable {
    public var enabled: Bool
    public var modelContextWindow: Int
    public var reserveTokens: Int
    public var keepRecentTokens: Int
    public var minMessagesToCompact: Int
    /// When the merged summary (old + new) exceeds this character count, the
    /// summariser is asked to consolidate the two into a single tighter
    /// summary instead of doing a character-suffix truncate.
    public var summaryConsolidateThreshold: Int
    /// After this many consecutive compaction failures, the loop falls back
    /// to dropping the oldest turn with a placeholder note. Prevents infinite
    /// retry loops when the summariser repeatedly fails.
    public var maxConsecutiveFailures: Int
    /// Builds the prompt sent to the model when summarising older history.
    /// Override to localise or to enforce a custom output schema.
    public var promptBuilder: CompactionPromptBuilder

    public init(
        enabled: Bool = true,
        modelContextWindow: Int = 128_000,
        reserveTokens: Int = 16_384,
        keepRecentTokens: Int = 20_000,
        minMessagesToCompact: Int = 8,
        summaryConsolidateThreshold: Int = 16_000,
        maxConsecutiveFailures: Int = 3,
        promptBuilder: @escaping CompactionPromptBuilder = CompactionConfig.defaultPromptBuilder
    ) {
        self.enabled = enabled
        self.modelContextWindow = modelContextWindow
        self.reserveTokens = reserveTokens
        self.keepRecentTokens = keepRecentTokens
        self.minMessagesToCompact = minMessagesToCompact
        self.summaryConsolidateThreshold = summaryConsolidateThreshold
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.promptBuilder = promptBuilder
    }

    public static let defaultPromptBuilder: CompactionPromptBuilder = { input in
        let trimmedPrev = input.previousSummary?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let previousSection: String
        if let trimmedPrev, !trimmedPrev.isEmpty {
            previousSection = "[Existing summary]\n\(trimmedPrev)\n\n"
        } else {
            previousSection = ""
        }

        let trimmedCustom = input.customInstructions?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let customSection: String
        if let trimmedCustom, !trimmedCustom.isEmpty {
            customSection = "[Additional instructions]\n\(trimmedCustom)\n\n"
        } else {
            customSection = ""
        }

        let splitTurnSection: String
        if input.isSplitTurn {
            splitTurnSection = """
            [Note]
            A split-turn is happening: the content being compacted is the first half of an unfinished turn. Preserve the key intermediate state and any open work items.

            """
        } else {
            splitTurnSection = ""
        }

        return """
        You are a conversation compactor. Compress the history below into a faithful structured summary. Do not invent.

        Output sections (markdown):
        ## Goal
        ## Constraints & Preferences
        ## Progress
        ### Done
        ### In Progress
        ### Blocked
        ## Key Decisions
        ## Next Steps
        ## Critical Context

        Requirements:
        - Preserve explicit user constraints, technical decisions, failure causes, and next steps.
        - Preserve key file paths, command outcomes, and error messages.
        - Do not include anything unrelated to the conversation.

        \(customSection)\(splitTurnSection)\(previousSection)[Conversation to compact]
        \(input.serializedConversation)
        """
    }
}

enum TokenEstimator {
    static func estimate(_ text: String) -> Int {
        max(1, text.count / 4)
    }
}

public struct ContextUsage: Sendable, Equatable {
    /// Estimated tokens currently occupying the model context window.
    public let usedTokens: Int
    /// Configured total context window size (tokens).
    public let totalTokens: Int
    /// Tokens reserved as headroom (for response generation, tool args, etc.).
    public let reservedTokens: Int

    public init(usedTokens: Int, totalTokens: Int, reservedTokens: Int) {
        self.usedTokens = usedTokens
        self.totalTokens = totalTokens
        self.reservedTokens = reservedTokens
    }

    /// Effective threshold beyond which auto-compaction triggers.
    public var threshold: Int {
        max(1_024, totalTokens - reservedTokens)
    }

    /// 0.0–1.0 progress against `totalTokens`.
    public var percent: Double {
        guard totalTokens > 0 else { return 0 }
        return min(1.0, Double(usedTokens) / Double(totalTokens))
    }
}
