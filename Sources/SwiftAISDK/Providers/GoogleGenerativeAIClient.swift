import Foundation

/// Adapter for Google's Gemini API via the Generative Language endpoint
/// (`generativelanguage.googleapis.com/v1beta`).
///
/// Structural notes (the shape that makes this adapter different):
///
/// - Roles collapse to `user` and `model`. `system` messages are folded into a
///   top-level `systemInstruction.parts[].text`. Our `tool` role becomes a
///   `user` turn whose parts are `functionResponse` parts (one per result).
/// - Tool results are parts inside a normal `user` turn — there's no
///   dedicated tool role on the wire.
/// - Function calls are `functionCall` parts inside a `model` turn,
///   intermixed with `text` parts in their original order.
/// - Reasoning ("thinking") is a `text` part flagged with `thought: true`.
///   The accompanying opaque `thoughtSignature` MUST be echoed back on
///   subsequent turns when continuing tool-using thought sequences (Gemini
///   may otherwise reject the request with `MISSING_THOUGHT_SIGNATURE`).
///   We reuse `LLMReasoning.signature` for the same purpose Anthropic uses
///   it.
/// - Function declarations use raw JSON Schema via `parametersJsonSchema`.
///
/// Auth: `x-goog-api-key` request header. `?key=` query auth is intentionally
/// not used — header form works for every endpoint that accepts the query
/// form and avoids URL-encoding the key.
public struct GoogleGenerativeAIClient: LLMClient {
    public let baseURL: URL
    public let apiKey: String?
    public let timeout: TimeInterval
    /// Enable Gemini 2.5+ thinking with this token budget (0 = disabled,
    /// >0 = enabled). Use a negative value (e.g. `-1`) to send Gemini's
    /// "dynamic thinking" sentinel where the model decides the budget itself.
    public let thinkingBudgetTokens: Int
    /// Surface reasoning back to the caller as `.reasoning` content blocks.
    /// Off by default to match the existing providers.
    public let includeThoughts: Bool

    private let transport = HTTPTransport(providerName: "Gemini Generative Language")

    public init(
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        apiKey: String?,
        timeout: TimeInterval = 120,
        thinkingBudgetTokens: Int = 0,
        includeThoughts: Bool = false
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.includeThoughts = includeThoughts
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

    /// Streaming model:
    ///
    /// `streamGenerateContent?alt=sse` emits standard SSE frames where every
    /// `data:` payload is an entire `GenerateContentResponse` JSON. There's
    /// no per-event diff; each frame carries the next chunk of
    /// `candidates[0].content.parts`.
    ///
    /// We accumulate per (output) part-index. A new `parts` index produces a
    /// `blockStart`. Subsequent appends to the same index produce the
    /// matching delta. We close blocks when `finishReason` arrives, then emit
    /// a single `messageStop` with the assembled `LLMResponse`.
    private func runStream(
        request: LLMRequest,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let urlRequest = try makeURLRequest(for: request, stream: true)
        let bytes = try await transport.sendStreaming(urlRequest)

        struct PartState {
            enum Kind { case text, reasoning, toolUse, unknown }
            var kind: Kind = .unknown
            var blockIndex: Int = -1
            var blockStarted: Bool = false
            // Accumulators
            var text: String = ""
            var reasoningText: String = ""
            var thoughtSignature: String?
            var toolID: String?
            var toolName: String?
            var toolArgsJSON: String = ""
        }

        var parts: [Int: PartState] = [:]
        var nextBlockIndex = 0
        var responseID: String?
        var stopReason: LLMStopReason? = nil
        var usage: LLMUsage? = nil
        var emittedMessageStart = false
        var sawAnyToolCall = false

        var parser = SSEParser()

        for try await line in bytes.lines {
            let events = parser.feed(line + "\n")
            for payload in events {
                guard let data = payload.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if responseID == nil, let rid = root["responseId"] as? String {
                    responseID = rid
                }

                if !emittedMessageStart {
                    continuation.yield(.messageStart(LLMStreamMessageStart(
                        providerResponseID: responseID
                    )))
                    emittedMessageStart = true
                }

                if let usageObj = root["usageMetadata"] as? [String: Any] {
                    usage = Self.parseUsage(usageObj)
                }

                guard let candidates = root["candidates"] as? [[String: Any]],
                      let first = candidates.first
                else { continue }

                if let content = first["content"] as? [String: Any],
                   let wireParts = content["parts"] as? [[String: Any]] {
                    for (index, part) in wireParts.enumerated() {
                        let isThought = (part["thought"] as? Bool) ?? false
                        var state = parts[index] ?? PartState()

                        // Determine kind from this part. Gemini sometimes
                        // splits a text run across multiple frames at the
                        // same position; we lock the kind on first sight.
                        if state.kind == .unknown {
                            if part["functionCall"] is [String: Any] {
                                state.kind = .toolUse
                            } else if isThought {
                                state.kind = .reasoning
                            } else if part["text"] is String {
                                state.kind = .text
                            }
                        }

                        switch state.kind {
                        case .text:
                            if !state.blockStarted {
                                state.blockIndex = nextBlockIndex
                                nextBlockIndex += 1
                                state.blockStarted = true
                                continuation.yield(.blockStart(LLMStreamBlockStart(
                                    blockIndex: state.blockIndex,
                                    kind: .text
                                )))
                            }
                            if let t = part["text"] as? String, !t.isEmpty {
                                state.text += t
                                continuation.yield(.textDelta(t))
                            }

                        case .reasoning:
                            if !state.blockStarted {
                                state.blockIndex = nextBlockIndex
                                nextBlockIndex += 1
                                state.blockStarted = true
                                continuation.yield(.blockStart(LLMStreamBlockStart(
                                    blockIndex: state.blockIndex,
                                    kind: .reasoning
                                )))
                            }
                            if let t = part["text"] as? String, !t.isEmpty {
                                state.reasoningText += t
                                continuation.yield(.reasoningDelta(LLMReasoningDelta(
                                    blockIndex: state.blockIndex,
                                    delta: t
                                )))
                            }
                            if let sig = part["thoughtSignature"] as? String,
                               state.thoughtSignature == nil {
                                state.thoughtSignature = sig
                            }

                        case .toolUse:
                            sawAnyToolCall = true
                            if let call = part["functionCall"] as? [String: Any] {
                                let id = (call["id"] as? String)
                                    ?? state.toolID
                                    ?? UUID().uuidString
                                let name = (call["name"] as? String) ?? state.toolName ?? ""
                                let args = call["args"]
                                let argsJSON: String
                                if let argsDict = args as? [String: Any] {
                                    argsJSON = JSONHelpers.serialize(argsDict)
                                } else if args == nil {
                                    argsJSON = "{}"
                                } else {
                                    argsJSON = JSONHelpers.serialize(args as Any)
                                }
                                if !state.blockStarted {
                                    state.blockIndex = nextBlockIndex
                                    nextBlockIndex += 1
                                    state.blockStarted = true
                                    state.toolID = id
                                    state.toolName = name
                                    continuation.yield(.blockStart(LLMStreamBlockStart(
                                        blockIndex: state.blockIndex,
                                        kind: .toolUse(id: id, name: name)
                                    )))
                                }
                                if argsJSON != state.toolArgsJSON {
                                    state.toolArgsJSON = argsJSON
                                    continuation.yield(.toolArgumentsDelta(LLMToolArgumentsDelta(
                                        blockIndex: state.blockIndex,
                                        delta: argsJSON
                                    )))
                                }
                            }

                        case .unknown:
                            break
                        }

                        parts[index] = state
                    }
                }

                if let raw = first["finishReason"] as? String {
                    stopReason = Self.mapFinishReason(raw, hasToolUse: sawAnyToolCall)
                }
            }
        }

        if !emittedMessageStart {
            continuation.yield(.messageStart(LLMStreamMessageStart(
                providerResponseID: responseID
            )))
        }

        // Close any still-open blocks in their original index order, then
        // assemble the final response.
        var assembled: [LLMContentBlock] = []
        for (_, state) in parts.sorted(by: { $0.key < $1.key }) {
            if state.blockStarted {
                continuation.yield(.blockStop(LLMStreamBlockStop(blockIndex: state.blockIndex)))
            }
            switch state.kind {
            case .text:
                assembled.append(.text(state.text))
            case .reasoning:
                assembled.append(.reasoning(LLMReasoning(
                    text: state.reasoningText,
                    signature: state.thoughtSignature
                )))
            case .toolUse:
                let id = state.toolID ?? UUID().uuidString
                assembled.append(.toolUse(LLMToolUse(
                    id: id,
                    name: state.toolName ?? "",
                    argumentsJSON: state.toolArgsJSON.isEmpty ? "{}" : state.toolArgsJSON
                )))
            case .unknown:
                continue
            }
        }

        let finalMessage = LLMMessage(role: .assistant, content: assembled)
        let finalResponse = LLMResponse(
            message: finalMessage,
            stopReason: stopReason ?? (sawAnyToolCall ? .toolUse : .endTurn),
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
            headers["x-goog-api-key"] = apiKey
        }
        let modelSegment = request.model.hasPrefix("models/")
            ? request.model
            : "models/\(request.model)"
        let suffix = stream ? "streamGenerateContent?alt=sse" : "generateContent"
        guard let url = URL(string: "\(baseURL.absoluteString)/\(modelSegment):\(suffix)") else {
            throw LLMError.invalidResponse("Failed to build Gemini URL")
        }
        return HTTPTransport.makeJSONRequest(
            url: url,
            body: try makeRequestBody(from: request, stream: stream),
            headers: headers,
            stream: stream,
            timeout: timeout
        )
    }

    func makeRequestBody(from request: LLMRequest, stream: Bool = false) throws -> Data {
        _ = stream  // streaming is encoded in the URL path, not the body

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
            "contents": encodeContents(conversational)
        ]
        if !systemTexts.isEmpty {
            payload["systemInstruction"] = [
                "parts": [["text": systemTexts.joined(separator: "\n\n")]]
            ]
        }

        var generationConfig: [String: Any] = [:]
        if let temperature = request.temperature {
            generationConfig["temperature"] = temperature
        }
        if let max = request.maxOutputTokens {
            generationConfig["maxOutputTokens"] = max
        }
        if thinkingBudgetTokens != 0 || includeThoughts {
            var thinking: [String: Any] = ["includeThoughts": includeThoughts]
            if thinkingBudgetTokens != 0 {
                thinking["thinkingBudget"] = thinkingBudgetTokens
            }
            generationConfig["thinkingConfig"] = thinking
        }
        if !generationConfig.isEmpty {
            payload["generationConfig"] = generationConfig
        }

        if !request.tools.isEmpty {
            payload["tools"] = [[
                "functionDeclarations": request.tools.map(toolSpecToWire)
            ]]
            if let toolConfig = encodeToolConfig(request.toolChoice) {
                payload["toolConfig"] = toolConfig
            }
        }

        for (key, value) in request.providerOptions {
            payload[key] = value.jsonObject
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    func encodeContents(_ messages: [LLMMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .user:
                let parts = message.content.compactMap { block -> [String: Any]? in
                    switch block {
                    case .text(let s):
                        return s.isEmpty ? nil : ["text": s]
                    case .image(let image):
                        return encodeImage(image)
                    default:
                        return nil
                    }
                }
                guard !parts.isEmpty else { continue }
                out.append(["role": "user", "parts": parts])

            case .assistant:
                var parts: [[String: Any]] = []
                for block in message.content {
                    switch block {
                    case .text(let s):
                        if !s.isEmpty { parts.append(["text": s]) }
                    case .reasoning(let reasoning):
                        // Echo thought parts back ONLY when we have a
                        // signature. A signature-less thought is opaque
                        // narration with no continuation value, and Gemini
                        // doesn't accept thought parts on input without one.
                        if let sig = reasoning.signature {
                            var part: [String: Any] = [
                                "text": reasoning.text,
                                "thought": true,
                                "thoughtSignature": sig
                            ]
                            // Stable ordering: append even if text is empty —
                            // the signature is the value being threaded.
                            if reasoning.text.isEmpty {
                                part["text"] = ""
                            }
                            parts.append(part)
                        }
                    case .toolUse(let use):
                        var call: [String: Any] = [
                            "name": use.name,
                            "args": JSONHelpers.parseObject(use.argumentsJSON)
                        ]
                        if !use.id.isEmpty {
                            call["id"] = use.id
                        }
                        parts.append(["functionCall": call])
                    case .refusal(let s):
                        if !s.isEmpty { parts.append(["text": s]) }
                    default:
                        continue
                    }
                }
                guard !parts.isEmpty else { continue }
                out.append(["role": "model", "parts": parts])

            case .tool:
                let resultParts = message.toolResults.map { result -> [String: Any] in
                    var fr: [String: Any] = [
                        "name": result.toolName,
                        // Wrap the textual tool result in `{ "output": <text> }`
                        // (or `{ "error": <text> }` on failure) — Gemini
                        // requires `response` to be a JSON object.
                        "response": result.isError
                            ? ["error": result.content]
                            : ["output": result.content]
                    ]
                    if !result.toolUseID.isEmpty {
                        fr["id"] = result.toolUseID
                    }
                    return ["functionResponse": fr]
                }
                guard !resultParts.isEmpty else { continue }
                out.append(["role": "user", "parts": resultParts])

            case .system:
                continue
            }
        }
        return out
    }

    private func encodeImage(_ image: LLMImage) -> [String: Any] {
        switch image.source {
        case .url(let url):
            // Gemini only accepts cloud URIs (gs://, https with allowed hosts)
            // through `fileData`. We pass it through; the server validates.
            return [
                "fileData": [
                    "mimeType": "image/*",
                    "fileUri": url.absoluteString
                ]
            ]
        case .base64(let mediaType, let data):
            return [
                "inlineData": [
                    "mimeType": mediaType,
                    "data": data
                ]
            ]
        }
    }

    private func toolSpecToWire(_ tool: LLMToolSpec) -> [String: Any] {
        let schema = JSONHelpers.parseAny(tool.argumentSchemaJSON)
        let parameters: Any = (schema as? [String: Any]) ?? ["type": "object"]
        return [
            "name": tool.name,
            "description": tool.description,
            "parametersJsonSchema": parameters
        ]
    }

    private func encodeToolConfig(_ choice: LLMToolChoice) -> [String: Any]? {
        switch choice {
        case .auto:
            return nil  // AUTO is the default; omit
        case .none:
            return ["functionCallingConfig": ["mode": "NONE"]]
        case .required:
            return ["functionCallingConfig": ["mode": "ANY"]]
        case .tool(let name):
            return [
                "functionCallingConfig": [
                    "mode": "ANY",
                    "allowedFunctionNames": [name]
                ]
            ]
        }
    }

    // MARK: - Response decoding

    private func parseResponse(_ data: Data) throws -> LLMResponse {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.decodingFailed("Invalid Gemini response: \(text)")
        }

        let candidates = (root["candidates"] as? [[String: Any]]) ?? []
        let first = candidates.first
        let content = (first?["content"] as? [String: Any]) ?? [:]
        let wireParts = (content["parts"] as? [[String: Any]]) ?? []

        // Coalesce contiguous `text` parts into a single `.text` block, keep
        // each `functionCall` and `thought` as its own block. Mirrors how we
        // assemble streaming output.
        var blocks: [LLMContentBlock] = []
        var pendingText = ""
        func flushPendingText() {
            if !pendingText.isEmpty {
                blocks.append(.text(pendingText))
                pendingText = ""
            }
        }
        var sawToolUse = false

        for part in wireParts {
            let isThought = (part["thought"] as? Bool) ?? false
            if let call = part["functionCall"] as? [String: Any] {
                flushPendingText()
                sawToolUse = true
                let id = (call["id"] as? String) ?? UUID().uuidString
                let name = (call["name"] as? String) ?? ""
                let argsJSON: String
                if let args = call["args"] as? [String: Any] {
                    argsJSON = JSONHelpers.serialize(args)
                } else {
                    argsJSON = "{}"
                }
                blocks.append(.toolUse(LLMToolUse(
                    id: id,
                    name: name,
                    argumentsJSON: argsJSON
                )))
            } else if isThought {
                flushPendingText()
                let text = (part["text"] as? String) ?? ""
                let signature = part["thoughtSignature"] as? String
                blocks.append(.reasoning(LLMReasoning(text: text, signature: signature)))
            } else if let text = part["text"] as? String {
                pendingText += text
            }
        }
        flushPendingText()

        let usage = (root["usageMetadata"] as? [String: Any]).map(Self.parseUsage)
        let stopReason = Self.mapFinishReason(
            first?["finishReason"] as? String,
            hasToolUse: sawToolUse
        )
        let id = root["responseId"] as? String

        return LLMResponse(
            message: LLMMessage(role: .assistant, content: blocks),
            stopReason: stopReason,
            usage: usage,
            providerResponseID: id
        )
    }

    private static func parseUsage(_ obj: [String: Any]) -> LLMUsage {
        LLMUsage(
            inputTokens: obj["promptTokenCount"] as? Int,
            outputTokens: obj["candidatesTokenCount"] as? Int,
            reasoningTokens: obj["thoughtsTokenCount"] as? Int,
            cachedInputTokens: obj["cachedContentTokenCount"] as? Int
        )
    }

    private static func mapFinishReason(_ raw: String?, hasToolUse: Bool) -> LLMStopReason? {
        // Gemini returns `STOP` even when the model emits a function call;
        // surface tool-use intent so callers don't have to special-case it.
        if hasToolUse {
            switch raw {
            case "STOP", nil, "":
                return .toolUse
            default:
                break
            }
        }
        switch raw {
        case .none, .some(""): return nil
        case "STOP": return .endTurn
        case "MAX_TOKENS": return .maxTokens
        case "STOP_SEQUENCE": return .stopSequence
        case .some(let other): return .other(other)
        }
    }
}
