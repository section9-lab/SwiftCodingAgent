import Foundation

public enum AgentRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct ToolCall: Codable, Sendable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String = UUID().uuidString, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// Result of a single tool invocation, paired with the originating tool call id.
public struct ToolResult: Codable, Sendable {
    public let toolCallID: String
    public let toolName: String
    public let content: String
    public let isError: Bool

    public init(toolCallID: String, toolName: String, content: String, isError: Bool = false) {
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.content = content
        self.isError = isError
    }
}

/// A single message in the agent's conversation history.
///
/// Replaces the earlier shape (which carried at most one tool call per message)
/// with a structure that natively supports parallel tool calls — required for
/// both OpenAI's `tool_calls` array and Anthropic's `tool_use` blocks.
///
/// Invariants:
/// - `system`/`user` messages: `text` is the payload; `toolCalls` and `toolResults` are empty.
/// - `assistant` messages: may have `text`, `toolCalls`, or both. `toolResults` empty.
/// - `tool` messages: carry one or more `toolResults`; `text` and `toolCalls` empty.
public struct AgentMessage: Identifiable, Codable, Sendable {
    public let id: UUID
    public let role: AgentRole
    public let text: String
    public let toolCalls: [ToolCall]
    public let toolResults: [ToolResult]

    public init(
        id: UUID = UUID(),
        role: AgentRole,
        text: String = "",
        toolCalls: [ToolCall] = [],
        toolResults: [ToolResult] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolResults = toolResults
    }

    /// Convenience for plain text messages.
    public static func system(_ text: String) -> AgentMessage { .init(role: .system, text: text) }
    public static func user(_ text: String) -> AgentMessage { .init(role: .user, text: text) }
    public static func assistant(_ text: String) -> AgentMessage { .init(role: .assistant, text: text) }
}

public struct ModelToolSpec: Codable, Sendable {
    public let name: String
    public let description: String
    public let argumentSchemaJSON: String

    public init(name: String, description: String, argumentSchemaJSON: String) {
        self.name = name
        self.description = description
        self.argumentSchemaJSON = argumentSchemaJSON
    }
}

public struct ModelRequest: Sendable {
    public let messages: [AgentMessage]
    public let tools: [ModelToolSpec]

    public init(messages: [AgentMessage], tools: [ModelToolSpec]) {
        self.messages = messages
        self.tools = tools
    }
}

public struct ModelUsage: Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct ModelResponse: Sendable {
    public let content: String
    public let toolCalls: [ToolCall]
    public let usage: ModelUsage?

    public init(content: String, toolCalls: [ToolCall] = [], usage: ModelUsage? = nil) {
        self.content = content
        self.toolCalls = toolCalls
        self.usage = usage
    }
}

public protocol AgentModel: Sendable {
    func generate(request: ModelRequest) async throws -> ModelResponse

    /// Streamed variant. Yields incremental text deltas as they arrive, plus
    /// fully-assembled tool calls (tool calls are NOT split into deltas — the
    /// adapter buffers the partial JSON arguments and emits a single
    /// `.toolCall` event per call once it's complete). Ends with `.completed`.
    ///
    /// The default implementation falls back to `generate` and synthesises a
    /// single text event followed by tool calls, so adapters that don't
    /// support streaming still satisfy the protocol.
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error>
}

public enum ModelStreamEvent: Sendable {
    /// Incremental text fragment from the assistant. Concatenate to build the
    /// full text.
    case textDelta(String)
    /// Incremental fragment of model "reasoning" / chain-of-thought. Some
    /// providers (NVIDIA NIM with GPT-OSS / DeepSeek-R1, Qwen-Thinking,
    /// upstream OpenAI o1-style endpoints) put this in a separate
    /// `reasoning_content` field — adapters surface those fragments here so
    /// callers can choose to display them in a collapsed/dimmed UI without
    /// mixing with the final answer.
    case reasoningDelta(String)
    /// A fully-assembled tool call. Emitted once the adapter has the complete
    /// arguments JSON.
    case toolCall(ToolCall)
    /// Final marker; carries the full assembled response so callers that don't
    /// want to track state themselves can grab it.
    case completed(ModelResponse)
}

public extension AgentModel {
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await generate(request: request)
                    if !response.content.isEmpty {
                        continuation.yield(.textDelta(response.content))
                    }
                    for call in response.toolCalls {
                        continuation.yield(.toolCall(call))
                    }
                    continuation.yield(.completed(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
