import Foundation

public enum AgentRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct AgentMessage: Identifiable, Codable, Sendable {
    public let id: UUID
    public let role: AgentRole
    public let content: String
    public let toolName: String?
    public let toolCallID: String?
    public let toolArgumentsJSON: String?

    public init(
        id: UUID = UUID(),
        role: AgentRole,
        content: String,
        toolName: String? = nil,
        toolCallID: String? = nil,
        toolArgumentsJSON: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.toolArgumentsJSON = toolArgumentsJSON
    }
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

public struct ModelResponse: Sendable {
    public let content: String
    public let toolCalls: [ToolCall]

    public init(content: String, toolCalls: [ToolCall] = []) {
        self.content = content
        self.toolCalls = toolCalls
    }
}

public protocol AgentModel: Sendable {
    func generate(request: ModelRequest) async throws -> ModelResponse
}
