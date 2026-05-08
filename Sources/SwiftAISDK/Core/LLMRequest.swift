import Foundation

/// Single request into an LLM client.
///
/// Provider-specific knobs that don't fit the common shape live in
/// `providerOptions` — a `[String: LLMOptionValue]` bag the corresponding
/// client adapter merges into the wire payload before sending. Use this for
/// things like Anthropic `thinking.budget_tokens`, Responses `reasoning.effort`,
/// or OpenAI `seed`. Keys unknown to a particular adapter are ignored.
public struct LLMRequest: Sendable {
    public let model: String
    public let messages: [LLMMessage]
    public let tools: [LLMToolSpec]
    public let toolChoice: LLMToolChoice
    public let temperature: Double?
    public let maxOutputTokens: Int?
    public let providerOptions: [String: LLMOptionValue]

    public init(
        model: String,
        messages: [LLMMessage],
        tools: [LLMToolSpec] = [],
        toolChoice: LLMToolChoice = .auto,
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil,
        providerOptions: [String: LLMOptionValue] = [:]
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.providerOptions = providerOptions
    }
}

/// Sendable JSON-ish value used for provider-specific request options.
/// Mirrors the subset of JSON we actually need to construct payloads:
/// strings, numbers, bools, nested objects, arrays, and explicit null.
public enum LLMOptionValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([LLMOptionValue])
    case object([String: LLMOptionValue])
    case null

    /// Bridge into a `JSONSerialization`-compatible value. Used by client
    /// encoders when assembling the request body.
    public var jsonObject: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let a): return a.map(\.jsonObject)
        case .object(let o): return o.mapValues(\.jsonObject)
        case .null: return NSNull()
        }
    }
}

/// Token usage reported by the provider.
public struct LLMUsage: Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    /// Reasoning tokens (Responses API) or thinking tokens (Anthropic). When
    /// reported separately by the provider; counted inside `outputTokens` for
    /// providers that don't break it out.
    public let reasoningTokens: Int?
    /// Cache-read tokens, if reported (Anthropic prompt caching, OpenAI
    /// Responses cached input). Informational only.
    public let cachedInputTokens: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        cachedInputTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cachedInputTokens = cachedInputTokens
    }
}

/// Reason the model stopped generating. `unknown` keeps providers we haven't
/// mapped explicitly from leaking provider strings into call-site logic.
public enum LLMStopReason: Sendable, Equatable {
    /// Natural completion (Anthropic `end_turn`, OpenAI `stop`).
    case endTurn
    /// Hit `maxOutputTokens` or `max_tokens` ceiling.
    case maxTokens
    /// Stopped because the model wants to invoke tools (Anthropic `tool_use`,
    /// OpenAI `tool_calls`).
    case toolUse
    /// Hit a configured stop sequence.
    case stopSequence
    /// Provider-specific reason we don't translate. Carries the raw string.
    case other(String)
}

/// Final assembled response for one model call.
public struct LLMResponse: Sendable {
    /// Assistant message produced by this turn. Always role `.assistant`.
    public let message: LLMMessage
    public let stopReason: LLMStopReason?
    public let usage: LLMUsage?
    /// Provider-assigned id for the response (Anthropic `id`, Responses
    /// `id`, Chat Completions `id`). Useful for logging and for Responses'
    /// `previous_response_id` continuity (which the agent loop doesn't yet
    /// use, but apps embedding the client may).
    public let providerResponseID: String?

    public init(
        message: LLMMessage,
        stopReason: LLMStopReason? = nil,
        usage: LLMUsage? = nil,
        providerResponseID: String? = nil
    ) {
        self.message = message
        self.stopReason = stopReason
        self.usage = usage
        self.providerResponseID = providerResponseID
    }
}
