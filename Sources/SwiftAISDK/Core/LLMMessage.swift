import Foundation

/// One message in an LLM conversation.
///
/// Replaces the older `text + toolCalls + toolResults` shape. A message is a
/// sequence of typed blocks; the same shape works for plain user prompts,
/// assistant turns mixing reasoning + text + tool calls, and tool-result
/// turns.
///
/// Role-specific invariants the encoders rely on:
/// - `system`/`user`: only `.text` and (for user) `.image` blocks.
/// - `assistant`: any of `.text`, `.reasoning`, `.toolUse`, `.refusal`.
/// - `tool`: one or more `.toolResult` blocks; nothing else.
public struct LLMMessage: Identifiable, Sendable {
    public let id: UUID
    public var role: LLMRole
    public var content: [LLMContentBlock]

    public init(id: UUID = UUID(), role: LLMRole, content: [LLMContentBlock]) {
        self.id = id
        self.role = role
        self.content = content
    }
}

public extension LLMMessage {
    static func system(_ text: String) -> LLMMessage {
        LLMMessage(role: .system, content: [.text(text)])
    }

    static func user(_ text: String) -> LLMMessage {
        LLMMessage(role: .user, content: [.text(text)])
    }

    static func assistant(_ text: String) -> LLMMessage {
        LLMMessage(role: .assistant, content: [.text(text)])
    }

    /// Concatenated `.text` blocks, in order. Useful for callers that only
    /// care about the visible response (most agent loops).
    var text: String {
        content.compactMap(\.asText).joined()
    }

    /// All `.toolUse` blocks, in order.
    var toolUses: [LLMToolUse] {
        content.compactMap(\.asToolUse)
    }

    /// All `.toolResult` blocks, in order.
    var toolResults: [LLMToolResult] {
        content.compactMap(\.asToolResult)
    }
}
