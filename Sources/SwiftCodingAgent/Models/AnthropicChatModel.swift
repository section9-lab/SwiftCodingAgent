import Foundation

/// Adapter for Anthropic's Messages API (https://api.anthropic.com/v1/messages).
///
/// Each internal `AgentMessage` corresponds to exactly one Anthropic turn:
/// - `assistant` messages carry both text and any number of `tool_use` blocks
/// - `tool` messages become a `user` turn whose blocks are `tool_result`s
/// - `system` messages are concatenated into the top-level `system` field
///
/// This avoids the fragile "merge consecutive same-role messages" pattern: the
/// loop guarantees an alternating user/assistant rhythm by construction.
public struct AnthropicChatModel: AgentModel {
    public let baseURL: URL
    public let apiKey: String?
    public let modelName: String
    public let maxTokens: Int
    public let anthropicVersion: String
    public let timeout: TimeInterval

    public init(
        baseURL: URL = URL(string: "https://api.anthropic.com/v1")!,
        apiKey: String?,
        modelName: String,
        maxTokens: Int = 4096,
        anthropicVersion: String = "2023-06-01",
        timeout: TimeInterval = 120
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelName = modelName
        self.maxTokens = maxTokens
        self.anthropicVersion = anthropicVersion
        self.timeout = timeout
    }

    public nonisolated func generate(request: ModelRequest) async throws -> ModelResponse {
        let url = baseURL.appendingPathComponent("messages")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        urlRequest.timeoutInterval = timeout

        urlRequest.httpBody = try makeRequestBody(from: request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "AnthropicChatModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        guard (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AnthropicChatModel", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Anthropic error (\(http.statusCode)): \(text)"])
        }

        return try parseResponse(data)
    }

    // MARK: - Request encoding

    nonisolated func makeRequestBody(from request: ModelRequest) throws -> Data {
        var systemTexts: [String] = []
        var conversational: [AgentMessage] = []
        for message in request.messages {
            if message.role == .system {
                if !message.text.isEmpty { systemTexts.append(message.text) }
            } else {
                conversational.append(message)
            }
        }

        var payload: [String: Any] = [
            "model": modelName,
            "max_tokens": maxTokens,
            "messages": encodeMessages(conversational)
        ]

        if !systemTexts.isEmpty {
            payload["system"] = systemTexts.joined(separator: "\n\n")
        }

        if !request.tools.isEmpty {
            payload["tools"] = request.tools.map { toolToDictionary($0) }
        }

        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    nonisolated func encodeMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []

        for message in messages {
            guard let encoded = encodeMessage(message) else { continue }
            result.append(encoded)
        }

        return result
    }

    private nonisolated func encodeMessage(_ message: AgentMessage) -> [String: Any]? {
        switch message.role {
        case .user:
            guard !message.text.isEmpty else { return nil }
            return [
                "role": "user",
                "content": [["type": "text", "text": message.text]]
            ]

        case .assistant:
            var blocks: [[String: Any]] = []
            if !message.text.isEmpty {
                blocks.append(["type": "text", "text": message.text])
            }
            for call in message.toolCalls {
                let argsData = call.argumentsJSON.data(using: .utf8) ?? Data("{}".utf8)
                let input = (try? JSONSerialization.jsonObject(with: argsData)) ?? [String: Any]()
                blocks.append([
                    "type": "tool_use",
                    "id": call.id,
                    "name": call.name,
                    "input": input
                ])
            }
            // An assistant message with neither text nor tool calls is dropped:
            // Anthropic rejects empty turns, and the loop would have skipped
            // appending it in the first place under normal flow.
            guard !blocks.isEmpty else { return nil }
            return ["role": "assistant", "content": blocks]

        case .tool:
            guard !message.toolResults.isEmpty else { return nil }
            let blocks = message.toolResults.map { result -> [String: Any] in
                [
                    "type": "tool_result",
                    "tool_use_id": result.toolCallID,
                    "content": result.content,
                    "is_error": result.isError
                ]
            }
            return ["role": "user", "content": blocks]

        case .system:
            return nil
        }
    }

    private nonisolated func toolToDictionary(_ tool: ModelToolSpec) -> [String: Any] {
        let schemaData = tool.argumentSchemaJSON.data(using: .utf8) ?? Data("{}".utf8)
        let schema = (try? JSONSerialization.jsonObject(with: schemaData)) ?? ["type": "object"]
        return [
            "name": tool.name,
            "description": tool.description,
            "input_schema": schema
        ]
    }

    // MARK: - Response decoding

    private nonisolated func parseResponse(_ data: Data) throws -> ModelResponse {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let blocks = root["content"] as? [[String: Any]]
        else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AnthropicChatModel", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid response JSON: \(text)"])
        }

        var textParts: [String] = []
        var toolCalls: [ToolCall] = []

        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { textParts.append(text) }
            case "tool_use":
                guard
                    let id = block["id"] as? String,
                    let name = block["name"] as? String
                else { continue }
                let input = block["input"] ?? [String: Any]()
                let argsData = (try? JSONSerialization.data(withJSONObject: input, options: [])) ?? Data("{}".utf8)
                let argumentsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
                toolCalls.append(ToolCall(id: id, name: name, argumentsJSON: argumentsJSON))
            default:
                continue
            }
        }

        let usage = (root["usage"] as? [String: Any]).map { u in
            ModelUsage(
                inputTokens: u["input_tokens"] as? Int,
                outputTokens: u["output_tokens"] as? Int
            )
        }

        return ModelResponse(
            content: textParts.joined(separator: "\n"),
            toolCalls: toolCalls,
            usage: usage
        )
    }
}
