import Foundation

public struct OpenAICompatibleChatModel: AgentModel {
    public let baseURL: URL
    public let apiKey: String?
    public let modelName: String
    public let timeout: TimeInterval

    public init(
        baseURL: URL,
        apiKey: String?,
        modelName: String,
        timeout: TimeInterval = 120
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelName = modelName
        self.timeout = timeout
    }

    public nonisolated func generate(request: ModelRequest) async throws -> ModelResponse {
        let url = baseURL.appendingPathComponent("chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.timeoutInterval = timeout

        urlRequest.httpBody = try makeRequestBody(from: request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAICompatibleChatModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        guard (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "OpenAICompatibleChatModel", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "OpenAI-compatible error (\(http.statusCode)): \(text)"])
        }

        return try parseResponse(data)
    }

    private nonisolated func makeRequestBody(from request: ModelRequest) throws -> Data {
        let payload: [String: Any] = [
            "model": modelName,
            "messages": request.messages.map { messageToDictionary($0) },
            "tools": request.tools.map { toolToDictionary($0) },
            "tool_choice": "auto",
            "temperature": 0.2,
            "stream": false
        ]

        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private nonisolated func messageToDictionary(_ message: AgentMessage) -> [String: Any] {
        switch message.role {
        case .tool:
            return [
                "role": "tool",
                "content": message.content,
                "tool_call_id": message.toolCallID ?? ""
            ]
        case .system, .user, .assistant:
            return [
                "role": roleString(message.role),
                "content": message.content
            ]
        }
    }

    private nonisolated func toolToDictionary(_ tool: ModelToolSpec) -> [String: Any] {
        let schemaData = tool.argumentSchemaJSON.data(using: .utf8) ?? Data("{}".utf8)
        let schema = (try? JSONSerialization.jsonObject(with: schemaData)) ?? ["type": "object"]

        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": schema
            ]
        ]
    }

    private nonisolated func roleString(_ role: AgentRole) -> String {
        switch role {
        case .system: return "system"
        case .user: return "user"
        case .assistant: return "assistant"
        case .tool: return "tool"
        }
    }

    private nonisolated func parseResponse(_ data: Data) throws -> ModelResponse {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "OpenAICompatibleChatModel", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid response JSON: \(text)"])
        }

        let content = (message["content"] as? String) ?? ""

        let rawToolCalls = (message["tool_calls"] as? [[String: Any]]) ?? []
        let toolCalls = rawToolCalls.compactMap { item -> ToolCall? in
            guard let function = item["function"] as? [String: Any],
                  let name = function["name"] as? String
            else {
                return nil
            }

            let id = (item["id"] as? String) ?? UUID().uuidString
            let argumentsJSON: String

            if let argString = function["arguments"] as? String {
                argumentsJSON = argString
            } else if let argObj = function["arguments"] {
                let argData = (try? JSONSerialization.data(withJSONObject: argObj, options: [])) ?? Data("{}".utf8)
                argumentsJSON = String(data: argData, encoding: .utf8) ?? "{}"
            } else {
                argumentsJSON = "{}"
            }

            return ToolCall(id: id, name: name, argumentsJSON: argumentsJSON)
        }

        return ModelResponse(content: content, toolCalls: toolCalls)
    }
}
