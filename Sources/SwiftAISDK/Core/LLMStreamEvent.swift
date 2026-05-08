import Foundation

/// Streaming events emitted by `LLMClient.stream`.
///
/// The event sequence is shaped so callers don't have to know which provider
/// produced it:
/// - `messageStart` — once, at the beginning.
/// - For each output content block: `blockStart` → zero or more deltas →
///   `blockStop`.
/// - `messageStop(finalResponse)` — once, at the end. The full assembled
///   message and usage are attached so callers that don't track state
///   themselves can grab everything in one place.
///
/// Provider-specific telemetry that doesn't fit the abstract events (mid-stream
/// citations, image generation progress, etc.) is dropped on the floor — the
/// abstract shape favours portability over completeness.
public enum LLMStreamEvent: Sendable {
    case messageStart(LLMStreamMessageStart)
    case blockStart(LLMStreamBlockStart)

    case textDelta(String)
    case reasoningDelta(LLMReasoningDelta)
    case toolArgumentsDelta(LLMToolArgumentsDelta)

    case blockStop(LLMStreamBlockStop)
    case messageStop(LLMResponse)
}

public struct LLMStreamMessageStart: Sendable {
    public let providerResponseID: String?

    public init(providerResponseID: String?) {
        self.providerResponseID = providerResponseID
    }
}

/// Marker for the start of a content block. `blockIndex` is the position
/// inside the assistant message and is stable for the lifetime of the block.
public struct LLMStreamBlockStart: Sendable {
    public enum Kind: Sendable {
        case text
        case reasoning
        case toolUse(id: String, name: String)
        case refusal
    }

    public let blockIndex: Int
    public let kind: Kind

    public init(blockIndex: Int, kind: Kind) {
        self.blockIndex = blockIndex
        self.kind = kind
    }
}

public struct LLMStreamBlockStop: Sendable {
    public let blockIndex: Int

    public init(blockIndex: Int) {
        self.blockIndex = blockIndex
    }
}

public struct LLMReasoningDelta: Sendable {
    public let blockIndex: Int
    public let delta: String

    public init(blockIndex: Int, delta: String) {
        self.blockIndex = blockIndex
        self.delta = delta
    }
}

public struct LLMToolArgumentsDelta: Sendable {
    public let blockIndex: Int
    /// Partial JSON fragment. Concatenate with previous deltas for the same
    /// `blockIndex` to assemble the full arguments JSON. The corresponding
    /// `blockStop` event marks the end.
    public let delta: String

    public init(blockIndex: Int, delta: String) {
        self.blockIndex = blockIndex
        self.delta = delta
    }
}
