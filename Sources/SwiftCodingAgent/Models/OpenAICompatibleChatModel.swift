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

        urlRequest.httpBody = try makeRequestBody(from: request, stream: false)

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

    public nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await self.runStream(request: request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated func runStream(
        request: ModelRequest,
        continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
    ) async throws {
        let url = baseURL.appendingPathComponent("chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.timeoutInterval = timeout
        urlRequest.httpBody = try makeRequestBody(from: request, stream: true)

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAICompatibleChatModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }
        guard (200...299).contains(http.statusCode) else {
            var collected = Data()
            for try await byte in bytes { collected.append(byte) }
            let text = String(data: collected, encoding: .utf8) ?? ""
            throw NSError(domain: "OpenAICompatibleChatModel", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "OpenAI-compatible error (\(http.statusCode)): \(text)"])
        }

        var parser = SSEParser()
        // Tool calls arrive as deltas indexed by position. We accumulate per
        // index and emit a single `.toolCall` event when the stream finishes.
        struct PartialCall {
            var id: String?
            var name: String = ""
            var arguments: String = ""
        }
        var partials: [Int: PartialCall] = [:]
        var fullText = ""

        for try await line in bytes.lines {
            let events = parser.feed(line + "\n")
            for payload in events {
                if payload == "[DONE]" {
                    continue
                }
                guard let data = payload.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = root["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let delta = first["delta"] as? [String: Any]
                else { continue }

                if let textDelta = delta["content"] as? String, !textDelta.isEmpty {
                    fullText += textDelta
                    continuation.yield(.textDelta(textDelta))
                }

                if let toolDeltas = delta["tool_calls"] as? [[String: Any]] {
                    for item in toolDeltas {
                        let index = (item["index"] as? Int) ?? 0
                        var partial = partials[index] ?? PartialCall()
                        if let id = item["id"] as? String, !id.isEmpty { partial.id = id }
                        if let function = item["function"] as? [String: Any] {
                            if let name = function["name"] as? String, !name.isEmpty {
                                partial.name += name
                            }
                            if let args = function["arguments"] as? String {
                                partial.arguments += args
                            }
                        }
                        partials[index] = partial
                    }
                }
            }
        }

        // Emit assembled tool calls in index order.
        let assembled: [ToolCall] = partials
            .sorted { $0.key < $1.key }
            .map { _, partial in
                ToolCall(
                    id: partial.id ?? UUID().uuidString,
                    name: partial.name,
                    argumentsJSON: partial.arguments.isEmpty ? "{}" : partial.arguments
                )
            }

        for call in assembled { continuation.yield(.toolCall(call)) }

        let assembledResponse = ModelResponse(content: fullText, toolCalls: assembled, usage: nil)
        continuation.yield(.completed(assembledResponse))
        continuation.finish()
    }

    nonisolated func makeRequestBody(from request: ModelRequest, stream: Bool = false) throws -> Data {
        let payload: [String: Any] = [
            "model": modelName,
            "messages": encodeMessages(request.messages),
            "tools": request.tools.map { toolToDictionary($0) },
            "tool_choice": "auto",
            "temperature": 0.2,
            "stream": stream
        ]

        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    /// Translate the loop's `[AgentMessage]` history into OpenAI's wire format.
    /// One internal `tool`-role message carrying multiple `ToolResult`s expands
    /// into one wire `role: "tool"` message per result, each tagged with the
    /// originating `tool_call_id`.
    nonisolated func encodeMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []

        for message in messages {
            switch message.role {
            case .system:
                out.append(["role": "system", "content": message.text])

            case .user:
                out.append(["role": "user", "content": message.text])

            case .assistant:
                var dict: [String: Any] = ["role": "assistant"]
                // OpenAI accepts content: null when only tool_calls are present.
                dict["content"] = message.text.isEmpty ? NSNull() : message.text
                if !message.toolCalls.isEmpty {
                    dict["tool_calls"] = message.toolCalls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.name,
                                "arguments": call.argumentsJSON
                            ]
                        ] as [String: Any]
                    }
                }
                out.append(dict)

            case .tool:
                for result in message.toolResults {
                    out.append([
                        "role": "tool",
                        "content": result.content,
                        "tool_call_id": result.toolCallID
                    ])
                }
            }
        }

        return out
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

        let usage = (root["usage"] as? [String: Any]).map { u in
            ModelUsage(
                inputTokens: u["prompt_tokens"] as? Int,
                outputTokens: u["completion_tokens"] as? Int
            )
        }

        return ModelResponse(content: content, toolCalls: toolCalls, usage: usage)
    }
}
