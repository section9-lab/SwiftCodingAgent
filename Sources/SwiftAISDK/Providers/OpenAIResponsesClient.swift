import Foundation
import EventSource

/// Adapter for OpenAI's Responses API (`/v1/responses`).
///
/// Differs structurally from Chat Completions:
/// - Input is `input: [item]` where items are typed (`message`,
///   `function_call`, `function_call_output`, `reasoning`, ...). Tool calls
///   are NOT nested inside an assistant `message` — they're top-level items.
/// - Function tool spec is flat: `{ type: "function", name, description,
///   parameters }`. No nested `function` key.
/// - Reasoning is preserved across turns when the previous response was
///   created with `include: ["reasoning.encrypted_content"]` and the encrypted
///   blob is echoed back as a `reasoning` input item. We always include the
///   encrypted content and round-trip any reasoning item we received.
public struct OpenAIResponsesClient: LLMClient {
    public let baseURL: URL
    public let apiKey: String?
    public let timeout: TimeInterval
    /// Whether to request `include: ["reasoning.encrypted_content"]` so we can
    /// thread reasoning state across turns. Off by default; enable for o1 /
    /// o3 / gpt-5 style models when you want reasoning continuity.
    public let includeEncryptedReasoning: Bool

    private let transport = HTTPTransport(providerName: "OpenAI Responses")

    public init(
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        apiKey: String?,
        timeout: TimeInterval = 120,
        includeEncryptedReasoning: Bool = false
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        self.includeEncryptedReasoning = includeEncryptedReasoning
    }

    // MARK: - LLMClient

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let urlRequest = try makeURLRequest(for: request, stream: false)
        let data = try await transport.send(urlRequest)
        return try parseResponse(data)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStream(request: request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Streaming

    private func runStream(
        request: LLMRequest,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let urlRequest = try makeURLRequest(for: request, stream: true)
        let bytes = try await transport.sendStreaming(urlRequest)

        // Responses streams typed events, each with a `type` field. We map
        // them onto our generic `LLMStreamEvent` shape and accumulate the
        // full output for the final `messageStop`.
        struct PartialItem {
            var kind: Kind = .unknown
            var id: String?
            var name: String?
            var callID: String?
            var text: String = ""
            var reasoningText: String = ""
            var summaryParts: [String] = []
            var encryptedContent: String?
            var argsJSON: String = ""
            var blockIndex: Int = -1
            // Whether we've already emitted a `blockStart` for this item.
            var blockStarted: Bool = false
        }
        enum Kind {
            case message
            case functionCall
            case reasoning
            case unknown
        }

        var items: [Int: PartialItem] = [:]
        var responseID: String?
        var stopReason: LLMStopReason? = nil
        var usage: LLMUsage? = nil
        var nextBlockIndex = 0
        var emittedMessageStart = false

        for try await sse in bytes.events {
            let payload = sse.data
            guard let data = payload.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = root["type"] as? String

            switch type {
            case "response.created", "response.in_progress":
                if let response = root["response"] as? [String: Any] {
                    responseID = response["id"] as? String
                }
                if !emittedMessageStart {
                    continuation.yield(.messageStart(LLMStreamMessageStart(
                        providerResponseID: responseID
                    )))
                    emittedMessageStart = true
                }

            case "response.output_item.added":
                let outputIndex = (root["output_index"] as? Int) ?? items.count
                guard let itemDict = root["item"] as? [String: Any] else { continue }
                var partial = PartialItem()
                let itemType = itemDict["type"] as? String
                partial.id = itemDict["id"] as? String
                switch itemType {
                case "message":
                    partial.kind = .message
                    partial.blockIndex = nextBlockIndex
                    nextBlockIndex += 1
                    continuation.yield(.blockStart(LLMStreamBlockStart(
                        blockIndex: partial.blockIndex,
                        kind: .text
                    )))
                    partial.blockStarted = true
                case "function_call":
                    partial.kind = .functionCall
                    partial.name = itemDict["name"] as? String
                    partial.callID = itemDict["call_id"] as? String
                    if let argsString = itemDict["arguments"] as? String, !argsString.isEmpty {
                        partial.argsJSON = argsString
                    }
                    partial.blockIndex = nextBlockIndex
                    nextBlockIndex += 1
                    let id = partial.callID ?? partial.id ?? UUID().uuidString
                    continuation.yield(.blockStart(LLMStreamBlockStart(
                        blockIndex: partial.blockIndex,
                        kind: .toolUse(id: id, name: partial.name ?? "")
                    )))
                    partial.blockStarted = true
                case "reasoning":
                    partial.kind = .reasoning
                    partial.encryptedContent = itemDict["encrypted_content"] as? String
                    partial.blockIndex = nextBlockIndex
                    nextBlockIndex += 1
                    continuation.yield(.blockStart(LLMStreamBlockStart(
                        blockIndex: partial.blockIndex,
                        kind: .reasoning
                    )))
                    partial.blockStarted = true
                default:
                    partial.kind = .unknown
                }
                items[outputIndex] = partial

            case "response.output_text.delta":
                let outputIndex = (root["output_index"] as? Int) ?? 0
                guard let delta = root["delta"] as? String, !delta.isEmpty else { continue }
                var partial = items[outputIndex] ?? PartialItem()
                partial.text += delta
                items[outputIndex] = partial
                continuation.yield(.textDelta(delta))

            case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
                let outputIndex = (root["output_index"] as? Int) ?? 0
                guard let delta = root["delta"] as? String, !delta.isEmpty else { continue }
                var partial = items[outputIndex] ?? PartialItem()
                partial.reasoningText += delta
                items[outputIndex] = partial
                if partial.blockIndex >= 0 {
                    continuation.yield(.reasoningDelta(LLMReasoningDelta(
                        blockIndex: partial.blockIndex,
                        delta: delta
                    )))
                }

            case "response.reasoning_summary_text.done":
                let outputIndex = (root["output_index"] as? Int) ?? 0
                guard let text = root["text"] as? String else { continue }
                var partial = items[outputIndex] ?? PartialItem()
                partial.summaryParts.append(text)
                items[outputIndex] = partial

            case "response.function_call_arguments.delta":
                let outputIndex = (root["output_index"] as? Int) ?? 0
                guard let delta = root["delta"] as? String, !delta.isEmpty else { continue }
                var partial = items[outputIndex] ?? PartialItem()
                partial.argsJSON += delta
                items[outputIndex] = partial
                if partial.blockIndex >= 0 {
                    continuation.yield(.toolArgumentsDelta(LLMToolArgumentsDelta(
                        blockIndex: partial.blockIndex,
                        delta: delta
                    )))
                }

            case "response.output_item.done":
                let outputIndex = (root["output_index"] as? Int) ?? 0
                // Pull final fields off the completed item so we don't lose
                // ids/encrypted_content that only appear in the `.done` payload.
                if let itemDict = root["item"] as? [String: Any], var partial = items[outputIndex] {
                    if partial.id == nil { partial.id = itemDict["id"] as? String }
                    if partial.callID == nil { partial.callID = itemDict["call_id"] as? String }
                    if partial.name == nil { partial.name = itemDict["name"] as? String }
                    if let enc = itemDict["encrypted_content"] as? String,
                       partial.encryptedContent == nil {
                        partial.encryptedContent = enc
                    }
                    if partial.kind == .functionCall, partial.argsJSON.isEmpty,
                       let args = itemDict["arguments"] as? String {
                        partial.argsJSON = args
                    }
                    items[outputIndex] = partial
                }
                if let partial = items[outputIndex], partial.blockStarted {
                    continuation.yield(.blockStop(LLMStreamBlockStop(
                        blockIndex: partial.blockIndex
                    )))
                }

            case "response.completed":
                if let response = root["response"] as? [String: Any] {
                    if let responseUsage = response["usage"] as? [String: Any] {
                        usage = Self.parseUsage(responseUsage)
                    }
                    if let status = response["status"] as? String {
                        stopReason = Self.mapStatus(status, hasFunctionCall: items.values.contains {
                            $0.kind == .functionCall
                        })
                    }
                }

            case "response.failed", "response.incomplete":
                if let response = root["response"] as? [String: Any],
                   let error = response["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw LLMError.streamingProtocol(message)
                }

            case "error":
                let message = (root["message"] as? String)
                    ?? (root["error"] as? [String: Any])?["message"] as? String
                    ?? "stream error"
                throw LLMError.streamingProtocol(message)

            default:
                break
            }
        }

        if !emittedMessageStart {
            continuation.yield(.messageStart(LLMStreamMessageStart(
                providerResponseID: responseID
            )))
        }

        // Assemble the final message preserving output order.
        var assembled: [LLMContentBlock] = []
        for (_, partial) in items.sorted(by: { $0.key < $1.key }) {
            switch partial.kind {
            case .message:
                if !partial.text.isEmpty {
                    assembled.append(.text(partial.text))
                }
            case .functionCall:
                let id = partial.callID ?? partial.id ?? UUID().uuidString
                assembled.append(.toolUse(LLMToolUse(
                    id: id,
                    name: partial.name ?? "",
                    argumentsJSON: partial.argsJSON.isEmpty ? "{}" : partial.argsJSON
                )))
            case .reasoning:
                let text = partial.reasoningText.isEmpty
                    ? partial.summaryParts.joined(separator: "\n\n")
                    : partial.reasoningText
                assembled.append(.reasoning(LLMReasoning(
                    text: text,
                    encryptedContent: partial.encryptedContent,
                    id: partial.id
                )))
            case .unknown:
                continue
            }
        }

        let finalMessage = LLMMessage(role: .assistant, content: assembled)
        let hasToolUse = assembled.contains { if case .toolUse = $0 { return true } else { return false } }
        let finalResponse = LLMResponse(
            message: finalMessage,
            stopReason: stopReason ?? (hasToolUse ? .toolUse : .endTurn),
            usage: usage,
            providerResponseID: responseID
        )
        continuation.yield(.messageStop(finalResponse))
        continuation.finish()
    }

    // MARK: - Request encoding

    private func makeURLRequest(for request: LLMRequest, stream: Bool) throws -> URLRequest {
        var headers: [String: String] = [:]
        if let apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        return HTTPTransport.makeJSONRequest(
            url: baseURL.appendingPathComponent("responses"),
            body: try makeRequestBody(from: request, stream: stream),
            headers: headers,
            stream: stream,
            timeout: timeout
        )
    }

    func makeRequestBody(from request: LLMRequest, stream: Bool = false) throws -> Data {
        var systemTexts: [String] = []
        var conversational: [LLMMessage] = []
        for message in request.messages {
            if message.role == .system {
                let s = message.text
                if !s.isEmpty { systemTexts.append(s) }
            } else {
                conversational.append(message)
            }
        }

        var payload: [String: Any] = [
            "model": request.model,
            "input": encodeInput(conversational),
            "stream": stream
        ]
        if !systemTexts.isEmpty {
            payload["instructions"] = systemTexts.joined(separator: "\n\n")
        }
        if let temperature = request.temperature {
            payload["temperature"] = temperature
        }
        if let max = request.maxOutputTokens {
            payload["max_output_tokens"] = max
        }
        if !request.tools.isEmpty {
            payload["tools"] = request.tools.map(toolSpecToWire)
            if let choice = encodeToolChoice(request.toolChoice) {
                payload["tool_choice"] = choice
            }
        }
        if includeEncryptedReasoning {
            payload["include"] = ["reasoning.encrypted_content"]
            // The Responses API only honours `include` for reasoning when
            // `store: false`; otherwise it expects you to use
            // `previous_response_id`. We default to `store: false` to keep
            // the client stateless.
            if payload["store"] == nil {
                payload["store"] = false
            }
        }
        for (key, value) in request.providerOptions {
            payload[key] = value.jsonObject
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    /// Build the typed `input: []` array. Tool calls + tool results are flat
    /// items, NOT nested in an assistant message — that's the Responses API's
    /// distinguishing structural choice and the main reason a Chat Completions
    /// adapter can't be reused.
    func encodeInput(_ messages: [LLMMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []

        for message in messages {
            switch message.role {
            case .user:
                let parts = message.content.compactMap { block -> [String: Any]? in
                    switch block {
                    case .text(let s):
                        return ["type": "input_text", "text": s]
                    case .image(let image):
                        return encodeInputImage(image)
                    default:
                        return nil
                    }
                }
                guard !parts.isEmpty else { continue }
                out.append([
                    "type": "message",
                    "role": "user",
                    "content": parts
                ])

            case .assistant:
                // Reasoning + text + tool calls are emitted as separate items,
                // in their original order, so the model sees the same shape it
                // produced.
                var pendingTextParts: [[String: Any]] = []
                func flushText(into out: inout [[String: Any]]) {
                    if !pendingTextParts.isEmpty {
                        out.append([
                            "type": "message",
                            "role": "assistant",
                            "content": pendingTextParts
                        ])
                        pendingTextParts.removeAll()
                    }
                }
                for block in message.content {
                    switch block {
                    case .reasoning(let reasoning):
                        flushText(into: &out)
                        var item: [String: Any] = [
                            "type": "reasoning",
                            "summary": [] // required field; can be empty
                        ]
                        if let id = reasoning.id { item["id"] = id }
                        if let enc = reasoning.encryptedContent {
                            item["encrypted_content"] = enc
                        }
                        out.append(item)
                    case .text(let s):
                        if !s.isEmpty {
                            pendingTextParts.append([
                                "type": "output_text",
                                "text": s
                            ])
                        }
                    case .toolUse(let use):
                        flushText(into: &out)
                        out.append([
                            "type": "function_call",
                            "call_id": use.id,
                            "name": use.name,
                            "arguments": use.argumentsJSON
                        ])
                    case .refusal(let s):
                        flushText(into: &out)
                        if !s.isEmpty {
                            out.append([
                                "type": "message",
                                "role": "assistant",
                                "content": [[
                                    "type": "refusal",
                                    "refusal": s
                                ]]
                            ])
                        }
                    default:
                        continue
                    }
                }
                flushText(into: &out)

            case .tool:
                for result in message.toolResults {
                    out.append([
                        "type": "function_call_output",
                        "call_id": result.toolUseID,
                        "output": result.content
                    ])
                }

            case .system:
                continue
            }
        }

        return out
    }

    private func encodeInputImage(_ image: LLMImage) -> [String: Any] {
        switch image.source {
        case .url(let url):
            return [
                "type": "input_image",
                "image_url": url.absoluteString
            ]
        case .base64(let mediaType, let data):
            return [
                "type": "input_image",
                "image_url": "data:\(mediaType);base64,\(data)"
            ]
        }
    }

    /// Function tools have a flat shape in the Responses API.
    private func toolSpecToWire(_ tool: LLMToolSpec) -> [String: Any] {
        let schema = JSONHelpers.parseAny(tool.argumentSchemaJSON)
        let parameters: Any = (schema as? [String: Any]) ?? ["type": "object"]
        return [
            "type": "function",
            "name": tool.name,
            "description": tool.description,
            "parameters": parameters
        ]
    }

    private func encodeToolChoice(_ choice: LLMToolChoice) -> Any? {
        switch choice {
        case .auto: return "auto"
        case .none: return "none"
        case .required: return "required"
        case .tool(let name):
            return ["type": "function", "name": name]
        }
    }

    // MARK: - Response decoding

    private func parseResponse(_ data: Data) throws -> LLMResponse {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.decodingFailed("Invalid Responses payload: \(text)")
        }

        let outputItems = (root["output"] as? [[String: Any]]) ?? []
        var blocks: [LLMContentBlock] = []

        for item in outputItems {
            switch item["type"] as? String {
            case "message":
                let parts = (item["content"] as? [[String: Any]]) ?? []
                var assembled = ""
                var refusalText: String?
                for part in parts {
                    switch part["type"] as? String {
                    case "output_text":
                        if let text = part["text"] as? String { assembled += text }
                    case "refusal":
                        refusalText = part["refusal"] as? String
                    default:
                        continue
                    }
                }
                if let refusalText, !refusalText.isEmpty {
                    blocks.append(.refusal(refusalText))
                }
                if !assembled.isEmpty {
                    blocks.append(.text(assembled))
                }

            case "function_call":
                let callID = (item["call_id"] as? String) ?? (item["id"] as? String) ?? UUID().uuidString
                let name = (item["name"] as? String) ?? ""
                let arguments = (item["arguments"] as? String) ?? "{}"
                blocks.append(.toolUse(LLMToolUse(
                    id: callID, name: name, argumentsJSON: arguments
                )))

            case "reasoning":
                let id = item["id"] as? String
                let encrypted = item["encrypted_content"] as? String
                let summary = (item["summary"] as? [[String: Any]]) ?? []
                let summaryText = summary
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n\n")
                let contentParts = (item["content"] as? [[String: Any]]) ?? []
                let contentText = contentParts
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n\n")
                let text = !contentText.isEmpty ? contentText : summaryText
                blocks.append(.reasoning(LLMReasoning(
                    text: text,
                    encryptedContent: encrypted,
                    id: id
                )))

            default:
                continue
            }
        }

        let usage = (root["usage"] as? [String: Any]).map(Self.parseUsage)
        let id = root["id"] as? String
        let status = root["status"] as? String
        let hasToolUse = blocks.contains { if case .toolUse = $0 { return true } else { return false } }
        let stopReason = Self.mapStatus(status, hasFunctionCall: hasToolUse)

        return LLMResponse(
            message: LLMMessage(role: .assistant, content: blocks),
            stopReason: stopReason,
            usage: usage,
            providerResponseID: id
        )
    }

    private static func parseUsage(_ obj: [String: Any]) -> LLMUsage {
        let inputDetails = obj["input_tokens_details"] as? [String: Any]
        let outputDetails = obj["output_tokens_details"] as? [String: Any]
        return LLMUsage(
            inputTokens: obj["input_tokens"] as? Int,
            outputTokens: obj["output_tokens"] as? Int,
            reasoningTokens: outputDetails?["reasoning_tokens"] as? Int,
            cachedInputTokens: inputDetails?["cached_tokens"] as? Int
        )
    }

    private static func mapStatus(_ raw: String?, hasFunctionCall: Bool) -> LLMStopReason? {
        switch raw {
        case "completed":
            return hasFunctionCall ? .toolUse : .endTurn
        case "incomplete":
            return .maxTokens
        case "failed", "cancelled":
            return raw.map(LLMStopReason.other)
        default:
            return nil
        }
    }
}
