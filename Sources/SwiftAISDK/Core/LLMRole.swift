import Foundation

/// Conversation role in an LLM exchange. Matches the canonical
/// system/user/assistant/tool roles used by every major chat-style API.
///
/// The `tool` role is logical-only. When encoding to wire formats:
/// - OpenAI Chat Completions: each tool result becomes its own `role: "tool"` message.
/// - OpenAI Responses: tool results become typed `function_call_output` items.
/// - Anthropic Messages: tool results live in a `role: "user"` turn.
public enum LLMRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}
