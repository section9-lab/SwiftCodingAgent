import Foundation

/// Adapter for Anthropic's Messages API (`/v1/messages`).
///
/// Each `LLMMessage` corresponds to exactly one Anthropic turn:
/// - `assistant` messages carry text, thinking, and any number of `tool_use`
///   blocks. Thinking blocks must round-trip with their `signature` intact —
///   the API rejects extended-thinking + tool-use multi-turn requests with a
///   missing or altered signature.
/// - `tool` messages become a `user` turn whose blocks are `tool_result`s.
/// - `system` messages are concatenated into the top-level `system` field.
///
/// Pass `extendedThinking: true` to enable Claude's extended thinking
/// (`thinking: { type: "enabled", budget_tokens: ... }`). The default is off
/// so callers don't accidentally pay the reasoning premium.
public struct AnthropicMessagesClient: LLMClient {
    public let baseURL: URL
    public let apiKey: String?
    public let anthropicVersion: String
    public let timeout: TimeInterval
    /// Default `max_tokens` when the request doesn't specify one. Required by
    /// the API.
    public let defaultMaxTokens: Int
    /// Enable extended thinking with this token budget (0 = disabled).
    public let thinkingBudgetTokens: Int

    private let transport = HTTPTransport(providerName: "Anthropic Messages")

    public init(
        baseURL: URL = URL(string: "https://api.anthropic.com/v1")!,
        apiKey: String?,
        anthropicVersion: String = "2023-06-01",
        timeout: TimeInterval = 120,
        defaultMaxTokens: Int = 4096,
        thinkingBudgetTokens: Int = 0
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.anthropicVersion = anthropicVersion
        self.timeout = timeout
        self.defaultMaxTokens = defaultMaxTokens
        self.thinkingBudgetTokens = thinkingBudgetTokens
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

        var parser = SSEParser()
        struct Block {
            var type: String = "text"
            var toolID: String?
            var toolName: String?
            var text: String = ""
            var argsJSON: String = ""
            var thinking: String = ""
            var signature: String?
            /// Set for `redacted_thinking` blocks; the full opaque blob is
            /// delivered in `content_block_start` (no deltas follow) and must
            /// round-trip verbatim on the next request.
            var redactedData: String?
        }
        var blocks: [Int: Block] = [:]
        var responseID: String?
        var stopReason: LLMStopReason? = nil
        var usage: LLMUsage? = nil
        var emittedMessageStart = false

        // Iterate raw bytes rather than `bytes.lines` because
        // `URLSession.AsyncBytes.lines` collapses consecutive line separators
        // on some platforms — and SSE uses the blank line as the event
        // terminator. Without it, SSEParser never emits an event.
        var byteAccum: [UInt8] = []
        for try await byte in bytes {
            byteAccum.append(byte)
            guard byte == 0x0A else { continue }
            let chunk = String(decoding: byteAccum, as: UTF8.self)
            byteAccum.removeAll(keepingCapacity: true)
            let events = parser.feed(chunk)
            for payload in events {
                guard let data = payload.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let type = root["type"] as? String

                switch type {
                case "message_start":
                    if let message = root["message"] as? [String: Any] {
                        responseID = message["id"] as? String
                        if let usageObj = message["usage"] as? [String: Any] {
                            usage = Self.parseUsage(usageObj)
                        }
                    }
                    if !emittedMessageStart {
                        continuation.yield(.messageStart(LLMStreamMessageStart(
                            providerResponseID: responseID
                        )))
                        emittedMessageStart = true
                    }

                case "content_block_start":
                    let index = (root["index"] as? Int) ?? 0
                    var block = Block()
                    if let cb = root["content_block"] as? [String: Any] {
                        block.type = (cb["type"] as? String) ?? "text"
                        block.toolID = cb["id"] as? String
                        block.toolName = cb["name"] as? String
                        // `redacted_thinking` arrives whole; its `data` is the
                        // opaque blob we must echo back on the next turn.
                        if block.type == "redacted_thinking" {
                            block.redactedData = cb["data"] as? String
                        }
                    }
                    blocks[index] = block
                    let kind: LLMStreamBlockStart.Kind
                    switch block.type {
                    case "tool_use":
                        kind = .toolUse(id: block.toolID ?? "", name: block.toolName ?? "")
                    case "thinking", "redacted_thinking":
                        kind = .reasoning
                    case "text":
                        kind = .text
                    default:
                        // Unknown block type — fall back to text. Better than dropping.
                        kind = .text
                    }
                    continuation.yield(.blockStart(LLMStreamBlockStart(
                        blockIndex: index,
                        kind: kind
                    )))

                case "content_block_delta":
                    let index = (root["index"] as? Int) ?? 0
                    var block = blocks[index] ?? Block()
                    if let delta = root["delta"] as? [String: Any] {
                        switch delta["type"] as? String {
                        case "text_delta":
                            if let t = delta["text"] as? String, !t.isEmpty {
                                block.text += t
                                continuation.yield(.textDelta(t))
                            }
                        case "thinking_delta":
                            if let t = delta["thinking"] as? String, !t.isEmpty {
                                block.thinking += t
                                continuation.yield(.reasoningDelta(LLMReasoningDelta(
                                    blockIndex: index,
                                    delta: t
                                )))
                            }
                        case "signature_delta":
                            // Signatures are accumulated, not streamed to caller — they're
                            // an opaque verification token, not human-readable content.
                            if let sig = delta["signature"] as? String {
                                block.signature = (block.signature ?? "") + sig
                            }
                        case "input_json_delta":
                            if let partial = delta["partial_json"] as? String {
                                block.argsJSON += partial
                                continuation.yield(.toolArgumentsDelta(LLMToolArgumentsDelta(
                                    blockIndex: index,
                                    delta: partial
                                )))
                            }
                        default:
                            break
                        }
                    }
                    blocks[index] = block

                case "content_block_stop":
                    let index = (root["index"] as? Int) ?? 0
                    continuation.yield(.blockStop(LLMStreamBlockStop(blockIndex: index)))

                case "message_delta":
                    if let delta = root["delta"] as? [String: Any] {
                        if let stop = delta["stop_reason"] as? String {
                            stopReason = Self.mapStopReason(stop)
                        }
                    }
                    if let usageObj = root["usage"] as? [String: Any] {
                        // `message_delta.usage` carries the *output* tokens
                        // for the turn; merge with the input tokens from
                        // `message_start.usage`.
                        let outputTokens = usageObj["output_tokens"] as? Int
                        usage = LLMUsage(
                            inputTokens: usage?.inputTokens,
                            outputTokens: outputTokens ?? usage?.outputTokens,
                            reasoningTokens: usage?.reasoningTokens,
                            cachedInputTokens: usage?.cachedInputTokens
                        )
                    }

                case "message_stop":
                    break

                case "error":
                    let message = (root["error"] as? [String: Any])?["message"] as? String ?? "stream error"
                    throw LLMError.streamingProtocol(message)

                default:
                    break
                }
            }
        }

        if !emittedMessageStart {
            continuation.yield(.messageStart(LLMStreamMessageStart(
                providerResponseID: responseID
            )))
        }

        // Reassemble final message in block-index order.
        let assembled = blocks
            .sorted { $0.key < $1.key }
            .compactMap { _, block -> LLMContentBlock? in
                switch block.type {
                case "text":
                    return .text(block.text)
                case "thinking":
                    return .reasoning(LLMReasoning(
                        text: block.thinking,
                        signature: block.signature
                    ))
                case "redacted_thinking":
                    return .reasoning(LLMReasoning(
                        text: "",
                        redactedData: block.redactedData
                    ))
                case "tool_use":
                    guard let id = block.toolID, let name = block.toolName else { return nil }
                    return .toolUse(LLMToolUse(
                        id: id,
                        name: name,
                        argumentsJSON: block.argsJSON.isEmpty ? "{}" : block.argsJSON
                    ))
                default:
                    return nil
                }
            }

        let finalMessage = LLMMessage(role: .assistant, content: assembled)
        let finalResponse = LLMResponse(
            message: finalMessage,
            stopReason: stopReason,
            usage: usage,
            providerResponseID: responseID
        )
        continuation.yield(.messageStop(finalResponse))
        continuation.finish()
    }

    // MARK: - Request encoding

    private func makeURLRequest(for request: LLMRequest, stream: Bool) throws -> URLRequest {
        var headers: [String: String] = ["anthropic-version": anthropicVersion]
        if let apiKey, !apiKey.isEmpty {
            headers["x-api-key"] = apiKey
        }
        return HTTPTransport.makeJSONRequest(
            url: baseURL.appendingPathComponent("messages"),
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

        let thinkingEnabled = thinkingBudgetTokens > 0

        var payload: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxOutputTokens ?? defaultMaxTokens,
            "messages": encodeMessages(conversational),
            "stream": stream
        ]
        // Anthropic rejects any temperature other than 1 when extended
        // thinking is enabled. Honour the caller's value when thinking is
        // off; force 1 (and ignore top_p / top_k) when it's on.
        if thinkingEnabled {
            payload["temperature"] = 1
        } else if let temperature = request.temperature {
            payload["temperature"] = temperature
        }
        if !systemTexts.isEmpty {
            payload["system"] = systemTexts.joined(separator: "\n\n")
        }
        if !request.tools.isEmpty {
            payload["tools"] = request.tools.map(toolSpecToWire)
            if let choice = encodeToolChoice(request.toolChoice) {
                payload["tool_choice"] = choice
            }
        }
        if thinkingEnabled {
            payload["thinking"] = [
                "type": "enabled",
                "budget_tokens": thinkingBudgetTokens
            ]
        }
        for (key, value) in request.providerOptions {
            payload[key] = value.jsonObject
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    func encodeMessages(_ messages: [LLMMessage]) -> [[String: Any]] {
        messages.compactMap(encodeMessage)
    }

    private func encodeMessage(_ message: LLMMessage) -> [String: Any]? {
        switch message.role {
        case .user:
            var parts: [[String: Any]] = []
            for block in message.content {
                switch block {
                case .text(let s):
                    if !s.isEmpty {
                        parts.append(["type": "text", "text": s])
                    }
                case .image(let image):
                    parts.append(encodeImage(image))
                default:
                    continue
                }
            }
            guard !parts.isEmpty else { return nil }
            return ["role": "user", "content": parts]

        case .assistant:
            var parts: [[String: Any]] = []
            for block in message.content {
                switch block {
                case .reasoning(let reasoning):
                    // Thinking blocks must be echoed back with their original
                    // signature when threading thinking + tool use across
                    // turns. Skipping the reasoning text isn't enough — the
                    // signature is what the API validates.
                    //
                    // Three shapes possible:
                    //   1. `redacted_thinking` — emitted as-is via its opaque
                    //      `data` blob; no signature, no text.
                    //   2. `thinking` with signature — round-tripped intact.
                    //   3. `thinking` without signature — Anthropic rejects
                    //      it with a missing-signature error, so drop the
                    //      block instead of poisoning the request. This
                    //      occurs when reasoning came from a non-Anthropic
                    //      provider, or the signature was lost.
                    if let redacted = reasoning.redactedData, !redacted.isEmpty {
                        parts.append([
                            "type": "redacted_thinking",
                            "data": redacted
                        ])
                    } else if let sig = reasoning.signature, !sig.isEmpty {
                        parts.append([
                            "type": "thinking",
                            "thinking": reasoning.text,
                            "signature": sig
                        ])
                    }
                    // else: silently drop — see comment above.
                case .text(let s):
                    if !s.isEmpty {
                        parts.append(["type": "text", "text": s])
                    }
                case .toolUse(let use):
                    let input = JSONHelpers.parseObject(use.argumentsJSON)
                    parts.append([
                        "type": "tool_use",
                        "id": use.id,
                        "name": use.name,
                        "input": input
                    ])
                case .refusal(let s):
                    if !s.isEmpty {
                        parts.append(["type": "text", "text": s])
                    }
                default:
                    continue
                }
            }
            guard !parts.isEmpty else { return nil }
            return ["role": "assistant", "content": parts]

        case .tool:
            let results = message.toolResults
            guard !results.isEmpty else { return nil }
            let blocks = results.map { result -> [String: Any] in
                [
                    "type": "tool_result",
                    "tool_use_id": result.toolUseID,
                    "content": result.content,
                    "is_error": result.isError
                ]
            }
            return ["role": "user", "content": blocks]

        case .system:
            return nil
        }
    }

    private func encodeImage(_ image: LLMImage) -> [String: Any] {
        switch image.source {
        case .url(let url):
            return [
                "type": "image",
                "source": [
                    "type": "url",
                    "url": url.absoluteString
                ]
            ]
        case .base64(let mediaType, let data):
            return [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": data
                ]
            ]
        }
    }

    private func toolSpecToWire(_ tool: LLMToolSpec) -> [String: Any] {
        let schema = JSONHelpers.parseAny(tool.argumentSchemaJSON)
        let inputSchema: Any = (schema as? [String: Any]) ?? ["type": "object"]
        return [
            "name": tool.name,
            "description": tool.description,
            "input_schema": inputSchema
        ]
    }

    private func encodeToolChoice(_ choice: LLMToolChoice) -> Any? {
        switch choice {
        case .auto:
            return ["type": "auto"]
        case .required:
            return ["type": "any"]
        case .tool(let name):
            return ["type": "tool", "name": name]
        case .none:
            // Anthropic has no native "none". We omit `tools` in the encoder
            // body when needed; for `tool_choice` itself, `nil` keeps the
            // default behaviour.
            return nil
        }
    }

    // MARK: - Response decoding

    private func parseResponse(_ data: Data) throws -> LLMResponse {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let blocks = root["content"] as? [[String: Any]]
        else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.decodingFailed("Invalid Anthropic response: \(text)")
        }

        var assembled: [LLMContentBlock] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String {
                    assembled.append(.text(text))
                }
            case "thinking":
                let text = (block["thinking"] as? String) ?? ""
                let signature = block["signature"] as? String
                assembled.append(.reasoning(LLMReasoning(text: text, signature: signature)))
            case "redacted_thinking":
                let data = (block["data"] as? String) ?? ""
                assembled.append(.reasoning(LLMReasoning(text: "", redactedData: data)))
            case "tool_use":
                guard let id = block["id"] as? String,
                      let name = block["name"] as? String else { continue }
                let input = block["input"] ?? [String: Any]()
                let argumentsJSON = JSONHelpers.serialize(input)
                assembled.append(.toolUse(LLMToolUse(
                    id: id, name: name, argumentsJSON: argumentsJSON
                )))
            default:
                continue
            }
        }

        let usage = (root["usage"] as? [String: Any]).map(Self.parseUsage)
        let stopReason = Self.mapStopReason(root["stop_reason"] as? String)
        let id = root["id"] as? String

        return LLMResponse(
            message: LLMMessage(role: .assistant, content: assembled),
            stopReason: stopReason,
            usage: usage,
            providerResponseID: id
        )
    }

    private static func parseUsage(_ obj: [String: Any]) -> LLMUsage {
        LLMUsage(
            inputTokens: obj["input_tokens"] as? Int,
            outputTokens: obj["output_tokens"] as? Int,
            reasoningTokens: nil,
            cachedInputTokens: obj["cache_read_input_tokens"] as? Int
        )
    }

    private static func mapStopReason(_ raw: String?) -> LLMStopReason? {
        switch raw {
        case .none: return nil
        case "end_turn": return .endTurn
        case "max_tokens": return .maxTokens
        case "tool_use": return .toolUse
        case "stop_sequence": return .stopSequence
        case .some(let other): return .other(other)
        }
    }
}
