import Foundation
import EventSource

/// Adapter for OpenAI's Chat Completions endpoint (`/v1/chat/completions`).
///
/// Also targets self-hosted and OpenAI-compatible endpoints (NVIDIA NIM,
/// vLLM, sglang, Ollama's OpenAI shim, Together, Groq, etc.). Set
/// `supportsTools: false` for endpoints that reject the request when `tools`
/// is present.
///
/// Reasoning models that emit chain-of-thought through a separate
/// `reasoning_content` field (DeepSeek-R1, Qwen-Thinking, NVIDIA NIM serving
/// gpt-oss) are surfaced as `.reasoning` content blocks. Those blocks have
/// no signature — Chat Completions has no concept of multi-turn reasoning
/// continuity, so the harness simply drops reasoning blocks before sending
/// follow-up requests.
public struct OpenAIChatCompletionsClient: LLMClient {
    public let baseURL: URL
    public let apiKey: String?
    public let timeout: TimeInterval
    /// Set to `false` for endpoints that 400 when `tools` appears.
    public let supportsTools: Bool

    private let transport = HTTPTransport(providerName: "OpenAI Chat Completions")

    public init(
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        apiKey: String?,
        timeout: TimeInterval = 120,
        supportsTools: Bool = true
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        self.supportsTools = supportsTools
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

        // Tool-call deltas arrive indexed by position. We accumulate per
        // index and emit a single tool-use block (with all argument fragments
        // forwarded as `toolArgumentsDelta`) once the stream finishes.
        struct PartialCall {
            var id: String?
            var name: String = ""
            var arguments: String = ""
            // Block index assigned the first time we see this call.
            var blockIndex: Int = -1
            var startedEmitted: Bool = false
        }

        var partials: [Int: PartialCall] = [:]
        var fullText = ""
        var fullReasoning = ""
        var responseID: String?
        var nextBlockIndex = 0
        var textBlockIndex: Int? = nil
        var reasoningBlockIndex: Int? = nil
        var stopReason: LLMStopReason? = nil
        var usage: LLMUsage? = nil
        var emittedMessageStart = false

        // mattt/EventSource handles CRLF/LF/CR, multi-line `data:`, and the
        // empty-separator edge case that breaks `URLSession.AsyncBytes.lines`.
        for try await sse in bytes.events {
            let payload = sse.data
            if payload == "[DONE]" { continue }

            guard let data = payload.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if !emittedMessageStart {
                responseID = root["id"] as? String
                continuation.yield(.messageStart(LLMStreamMessageStart(
                    providerResponseID: responseID
                )))
                emittedMessageStart = true
            }

            if let usageObj = root["usage"] as? [String: Any] {
                usage = Self.parseUsage(usageObj)
            }

            guard let choices = root["choices"] as? [[String: Any]],
                  let first = choices.first
            else { continue }

            if let finishReason = first["finish_reason"] as? String {
                stopReason = Self.mapStopReason(finishReason)
            }

            guard let delta = first["delta"] as? [String: Any] else { continue }

            if let textDelta = delta["content"] as? String, !textDelta.isEmpty {
                if textBlockIndex == nil {
                    textBlockIndex = nextBlockIndex
                    nextBlockIndex += 1
                    continuation.yield(.blockStart(LLMStreamBlockStart(
                        blockIndex: textBlockIndex!,
                        kind: .text
                    )))
                }
                fullText += textDelta
                continuation.yield(.textDelta(textDelta))
            }

            if let reasoningDelta = delta["reasoning_content"] as? String, !reasoningDelta.isEmpty {
                if reasoningBlockIndex == nil {
                    reasoningBlockIndex = nextBlockIndex
                    nextBlockIndex += 1
                    continuation.yield(.blockStart(LLMStreamBlockStart(
                        blockIndex: reasoningBlockIndex!,
                        kind: .reasoning
                    )))
                }
                fullReasoning += reasoningDelta
                continuation.yield(.reasoningDelta(LLMReasoningDelta(
                    blockIndex: reasoningBlockIndex!,
                    delta: reasoningDelta
                )))
            }

            if let toolDeltas = delta["tool_calls"] as? [[String: Any]] {
                for item in toolDeltas {
                    let providerIndex = (item["index"] as? Int) ?? 0
                    var partial = partials[providerIndex] ?? PartialCall()
                    if let id = item["id"] as? String, !id.isEmpty { partial.id = id }
                    var nameFragment = ""
                    var argsFragment = ""
                    if let function = item["function"] as? [String: Any] {
                        if let name = function["name"] as? String, !name.isEmpty {
                            partial.name += name
                            nameFragment = name
                        }
                        if let args = function["arguments"] as? String {
                            partial.arguments += args
                            argsFragment = args
                        }
                    }
                    if !partial.startedEmitted, !partial.name.isEmpty, partial.id != nil {
                        partial.blockIndex = nextBlockIndex
                        nextBlockIndex += 1
                        continuation.yield(.blockStart(LLMStreamBlockStart(
                            blockIndex: partial.blockIndex,
                            kind: .toolUse(id: partial.id!, name: partial.name)
                        )))
                        partial.startedEmitted = true
                    }
                    if partial.startedEmitted, !argsFragment.isEmpty {
                        continuation.yield(.toolArgumentsDelta(LLMToolArgumentsDelta(
                            blockIndex: partial.blockIndex,
                            delta: argsFragment
                        )))
                    }
                    _ = nameFragment
                    partials[providerIndex] = partial
                }
            }
        }

        // If we never saw a single SSE chunk (some misbehaving providers do
        // this on success), still emit messageStart so the caller can finish
        // cleanly.
        if !emittedMessageStart {
            continuation.yield(.messageStart(LLMStreamMessageStart(
                providerResponseID: nil
            )))
        }

        if let textBlockIndex {
            continuation.yield(.blockStop(LLMStreamBlockStop(blockIndex: textBlockIndex)))
        }
        if let reasoningBlockIndex {
            continuation.yield(.blockStop(LLMStreamBlockStop(blockIndex: reasoningBlockIndex)))
        }

        // Assemble tool-use blocks in provider-index order.
        var assembledBlocks: [LLMContentBlock] = []
        if let textBlockIndex {
            _ = textBlockIndex
            assembledBlocks.append(.text(fullText))
        }
        if let reasoningBlockIndex {
            _ = reasoningBlockIndex
            assembledBlocks.append(.reasoning(LLMReasoning(text: fullReasoning)))
        }
        // Reasoning models (NIM gpt-oss) sometimes stream the entire answer
        // through `reasoning_content` and never emit a `content` delta. If so,
        // we surface the reasoning as the text answer instead — keeps the
        // caller from seeing an empty assistant response.
        if assembledBlocks.allSatisfy({ if case .text = $0 { return false } else { return true } }),
           !fullReasoning.isEmpty,
           !partials.values.contains(where: { $0.startedEmitted }) {
            assembledBlocks = [.text(fullReasoning)]
        }

        let assembledTools = partials
            .sorted { $0.key < $1.key }
            .compactMap { _, partial -> (Int, LLMContentBlock)? in
                guard partial.startedEmitted else { return nil }
                continuation.yield(.blockStop(LLMStreamBlockStop(blockIndex: partial.blockIndex)))
                let toolUse = LLMToolUse(
                    id: partial.id ?? UUID().uuidString,
                    name: partial.name,
                    argumentsJSON: partial.arguments.isEmpty ? "{}" : partial.arguments
                )
                return (partial.blockIndex, .toolUse(toolUse))
            }
            .map { $0.1 }

        assembledBlocks.append(contentsOf: assembledTools)

        let finalMessage = LLMMessage(role: .assistant, content: assembledBlocks)
        let finalResponse = LLMResponse(
            message: finalMessage,
            stopReason: stopReason ?? (assembledTools.isEmpty ? .endTurn : .toolUse),
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
            url: baseURL.appendingPathComponent("chat/completions"),
            body: try makeRequestBody(from: request, stream: stream),
            headers: headers,
            stream: stream,
            timeout: timeout
        )
    }

    func makeRequestBody(from request: LLMRequest, stream: Bool = false) throws -> Data {
        var payload: [String: Any] = [
            "model": request.model,
            "messages": encodeMessages(request.messages),
            "stream": stream
        ]
        if let temperature = request.temperature {
            payload["temperature"] = temperature
        }
        if let maxOutputTokens = request.maxOutputTokens {
            payload["max_tokens"] = maxOutputTokens
        }
        if supportsTools && !request.tools.isEmpty {
            payload["tools"] = request.tools.map(toolSpecToWire)
            if let choice = encodeToolChoice(request.toolChoice) {
                payload["tool_choice"] = choice
            }
        }
        for (key, value) in request.providerOptions {
            payload[key] = value.jsonObject
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    /// Translate `[LLMMessage]` into the OpenAI Chat Completions wire shape.
    /// One internal `tool` message carrying multiple `LLMToolResult`s expands
    /// into one wire `role: "tool"` message per result.
    func encodeMessages(_ messages: [LLMMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []

        for message in messages {
            switch message.role {
            case .system:
                out.append(["role": "system", "content": message.text])

            case .user:
                out.append(encodeUserMessage(message))

            case .assistant:
                out.append(encodeAssistantMessage(message))

            case .tool:
                for result in message.toolResults {
                    out.append([
                        "role": "tool",
                        "content": result.content,
                        "tool_call_id": result.toolUseID
                    ])
                }
            }
        }

        return out
    }

    private func encodeUserMessage(_ message: LLMMessage) -> [String: Any] {
        // If the message has only text, use the simple string form so cheap
        // models that don't accept the array form still work.
        let onlyText = message.content.allSatisfy { if case .text = $0 { return true } else { return false } }
        if onlyText {
            return ["role": "user", "content": message.text]
        }

        var parts: [[String: Any]] = []
        for block in message.content {
            switch block {
            case .text(let s):
                parts.append(["type": "text", "text": s])
            case .image(let image):
                parts.append(encodeImageBlock(image))
            default:
                continue
            }
        }
        return ["role": "user", "content": parts]
    }

    private func encodeImageBlock(_ image: LLMImage) -> [String: Any] {
        let urlString: String
        switch image.source {
        case .url(let url):
            urlString = url.absoluteString
        case .base64(let mediaType, let data):
            urlString = "data:\(mediaType);base64,\(data)"
        }
        var imageURL: [String: Any] = ["url": urlString]
        if let detail = image.detail { imageURL["detail"] = detail }
        return ["type": "image_url", "image_url": imageURL]
    }

    private func encodeAssistantMessage(_ message: LLMMessage) -> [String: Any] {
        var dict: [String: Any] = ["role": "assistant"]
        let text = message.text
        let toolUses = message.toolUses

        // OpenAI accepts `content: null` when only tool_calls are present.
        dict["content"] = text.isEmpty ? NSNull() : text

        if !toolUses.isEmpty {
            dict["tool_calls"] = toolUses.map { use -> [String: Any] in
                [
                    "id": use.id,
                    "type": "function",
                    "function": [
                        "name": use.name,
                        "arguments": use.argumentsJSON
                    ]
                ]
            }
        }
        // Reasoning blocks are not echoed back — Chat Completions has no
        // multi-turn reasoning continuity, and sending them back as text would
        // confuse the model.
        return dict
    }

    private func toolSpecToWire(_ tool: LLMToolSpec) -> [String: Any] {
        let schema = JSONHelpers.parseAny(tool.argumentSchemaJSON)
        let parameters: Any = (schema as? [String: Any]) ?? ["type": "object"]
        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": parameters
            ]
        ]
    }

    private func encodeToolChoice(_ choice: LLMToolChoice) -> Any? {
        switch choice {
        case .auto: return "auto"
        case .none: return "none"
        case .required: return "required"
        case .tool(let name):
            return [
                "type": "function",
                "function": ["name": name]
            ]
        }
    }

    // MARK: - Response decoding

    private func parseResponse(_ data: Data) throws -> LLMResponse {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.decodingFailed("Invalid Chat Completions response: \(text)")
        }

        let rawContent = (message["content"] as? String) ?? ""
        let reasoningText = (message["reasoning_content"] as? String) ?? ""

        var blocks: [LLMContentBlock] = []
        if !reasoningText.isEmpty {
            blocks.append(.reasoning(LLMReasoning(text: reasoningText)))
        }
        if !rawContent.isEmpty {
            blocks.append(.text(rawContent))
        } else if reasoningText.isEmpty {
            // Preserve the empty assistant turn shape so consumers can still
            // see the message; tool calls below will fill it in.
            blocks.append(.text(""))
        }

        if let rawToolCalls = message["tool_calls"] as? [[String: Any]] {
            for item in rawToolCalls {
                guard let function = item["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let id = (item["id"] as? String) ?? UUID().uuidString
                let argumentsJSON: String
                if let argString = function["arguments"] as? String {
                    argumentsJSON = argString
                } else if let argObj = function["arguments"] {
                    argumentsJSON = JSONHelpers.serialize(argObj)
                } else {
                    argumentsJSON = "{}"
                }
                blocks.append(.toolUse(LLMToolUse(
                    id: id, name: name, argumentsJSON: argumentsJSON
                )))
            }
        }

        // Drop the placeholder empty `.text("")` block when we ended up with
        // tool calls or reasoning — it's just noise then.
        if blocks.count > 1, case .text(let s) = blocks[blocks.firstIndex(where: {
            if case .text = $0 { return true } else { return false }
        }) ?? blocks.startIndex], s.isEmpty {
            blocks.removeAll {
                if case .text(let t) = $0 { return t.isEmpty }
                return false
            }
        }

        let usage = (root["usage"] as? [String: Any]).flatMap(Self.parseUsage)
        let stopReason = Self.mapStopReason(first["finish_reason"] as? String)
        let id = root["id"] as? String

        return LLMResponse(
            message: LLMMessage(role: .assistant, content: blocks),
            stopReason: stopReason,
            usage: usage,
            providerResponseID: id
        )
    }

    private static func parseUsage(_ obj: [String: Any]) -> LLMUsage {
        let cached = (obj["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
        return LLMUsage(
            inputTokens: obj["prompt_tokens"] as? Int,
            outputTokens: obj["completion_tokens"] as? Int,
            reasoningTokens: (obj["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int,
            cachedInputTokens: cached
        )
    }

    private static func mapStopReason(_ raw: String?) -> LLMStopReason? {
        switch raw {
        case .none: return nil
        case "stop": return .endTurn
        case "length": return .maxTokens
        case "tool_calls", "function_call": return .toolUse
        case .some(let other): return .other(other)
        }
    }
}
