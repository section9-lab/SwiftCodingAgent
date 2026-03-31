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
