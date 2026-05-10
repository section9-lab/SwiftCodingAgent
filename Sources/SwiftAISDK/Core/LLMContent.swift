import Foundation

/// Provider-agnostic content block. Every block maps losslessly to a single
/// content fragment in the wire format of OpenAI Chat Completions, OpenAI
/// Responses, and Anthropic Messages.
///
/// Key invariants:
/// - `reasoning` blocks may carry an opaque `signature` (Anthropic) or
///   `encryptedContent` (OpenAI Responses). The agent runtime MUST pass these
///   back verbatim on follow-up turns when the reasoning was emitted alongside
///   tool calls — Anthropic rejects multi-turn extended-thinking + tool-use
///   requests when the signature is missing or altered.
/// - `toolUse.argumentsJSON` is always a JSON string (matching OpenAI's wire
///   shape). Anthropic's `input` object is parsed from / serialised to this
///   string at the encoder boundary.
/// - `toolResult.content` is plain text. Multi-modal tool results (Anthropic
///   supports image blocks inside `tool_result`) are not yet modelled — they
///   would extend this enum, not the existing case.
public enum LLMContentBlock: Sendable {
    case text(String)
    case image(LLMImage)
    case reasoning(LLMReasoning)
    case toolUse(LLMToolUse)
    case toolResult(LLMToolResult)
    case refusal(String)
}

public extension LLMContentBlock {
    /// Plain text payload, if this is a `.text` block. Returns nil otherwise.
    var asText: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    /// Tool-use payload, if this is a `.toolUse` block.
    var asToolUse: LLMToolUse? {
        if case .toolUse(let t) = self { return t }
        return nil
    }

    /// Tool-result payload, if this is a `.toolResult` block.
    var asToolResult: LLMToolResult? {
        if case .toolResult(let r) = self { return r }
        return nil
    }

    /// Reasoning payload, if this is a `.reasoning` block.
    var asReasoning: LLMReasoning? {
        if case .reasoning(let r) = self { return r }
        return nil
    }
}

/// One reasoning / chain-of-thought fragment.
///
/// Carries provider-specific opaque tokens used to validate the reasoning on
/// follow-up turns. These tokens are required for correctness:
/// - **Anthropic extended thinking**: when a `thinking` block precedes a
///   `tool_use`, the `signature` must be echoed back unchanged in the
///   subsequent assistant turn or the API rejects the request.
/// - **OpenAI Responses**: when reasoning is included via
///   `include: ["reasoning.encrypted_content"]`, the encrypted blob must
///   round-trip on the next request to keep the chain coherent.
public struct LLMReasoning: Sendable {
    /// Visible reasoning text (Anthropic `thinking`, Responses
    /// `reasoning.summary[*].text` or `reasoning.content[*].text`).
    public var text: String
    /// Anthropic thinking signature. Pass back verbatim when threading
    /// thinking + tool use across turns.
    public var signature: String?
    /// OpenAI Responses encrypted reasoning payload. Pass back verbatim to
    /// preserve hidden state.
    public var encryptedContent: String?
    /// OpenAI Responses reasoning item id. Used to maintain ordering when
    /// rebuilding the input array on follow-up turns.
    public var id: String?
    /// Anthropic `redacted_thinking` opaque blob. When set, this block was
    /// produced by the safety classifier and the visible `text` is empty;
    /// the encoder must emit `redacted_thinking` (not `thinking`) so the
    /// blob round-trips intact on follow-up turns.
    public var redactedData: String?

    public init(
        text: String,
        signature: String? = nil,
        encryptedContent: String? = nil,
        id: String? = nil,
        redactedData: String? = nil
    ) {
        self.text = text
        self.signature = signature
        self.encryptedContent = encryptedContent
        self.id = id
        self.redactedData = redactedData
    }
}

/// One tool invocation requested by the model.
public struct LLMToolUse: Sendable {
    public let id: String
    public let name: String
    /// JSON-encoded arguments. Always a string for cross-provider consistency.
    /// May be `"{}"` for tools that take no parameters.
    public let argumentsJSON: String

    public init(id: String = UUID().uuidString, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// Result of a single tool invocation, paired with the originating tool-use id.
public struct LLMToolResult: Sendable {
    public let toolUseID: String
    public let toolName: String
    public let content: String
    public let isError: Bool

    public init(toolUseID: String, toolName: String, content: String, isError: Bool = false) {
        self.toolUseID = toolUseID
        self.toolName = toolName
        self.content = content
        self.isError = isError
    }
}

/// Image input attached to a user message. Output images aren't modelled here
/// — both providers stream images out via different mechanisms (Responses
/// `image_generation_call`, Anthropic via tool calls).
public struct LLMImage: Sendable {
    public enum Source: Sendable {
        case url(URL)
        case base64(mediaType: String, data: String)
    }

    public var source: Source
    /// OpenAI-specific detail hint (`low` | `high` | `auto`). Anthropic
    /// ignores this.
    public var detail: String?

    public init(source: Source, detail: String? = nil) {
        self.source = source
        self.detail = detail
    }
}
