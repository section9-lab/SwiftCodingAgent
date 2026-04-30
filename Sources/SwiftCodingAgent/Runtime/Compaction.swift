import Foundation

public struct CompactionConfig: Sendable {
    public var enabled: Bool
    public var modelContextWindow: Int
    public var reserveTokens: Int
    public var keepRecentTokens: Int
    public var minMessagesToCompact: Int
    public var maxSummaryChars: Int

    public init(
        enabled: Bool = true,
        modelContextWindow: Int = 128_000,
        reserveTokens: Int = 16_384,
        keepRecentTokens: Int = 20_000,
        minMessagesToCompact: Int = 8,
        maxSummaryChars: Int = 16_000
    ) {
        self.enabled = enabled
        self.modelContextWindow = modelContextWindow
        self.reserveTokens = reserveTokens
        self.keepRecentTokens = keepRecentTokens
        self.minMessagesToCompact = minMessagesToCompact
        self.maxSummaryChars = maxSummaryChars
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
