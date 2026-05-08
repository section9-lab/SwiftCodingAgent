# Ollama 兼容性对比

本文档对比 SwiftAISDK 当前实现与 Ollama 的 OpenAI / Anthropic 兼容层，标注差异和缺失功能。

## 概述

SwiftAISDK 的三个客户端（`OpenAIChatCompletionsClient`、`OpenAIResponsesClient`、`AnthropicMessagesClient`）**已经完全兼容 Ollama**，因为它们实现的是上游 OpenAI / Anthropic 的官方协议。Ollama 的兼容层是 OpenAI / Anthropic API 的子集，因此任何能对接官方 API 的客户端自动兼容 Ollama。

唯一需要注意的是：Ollama 不支持的字段（如 `tool_choice`、`logit_bias`）在发送时会被 Ollama 忽略或拒绝，但这是 Ollama 的限制，不是 SwiftAISDK 的问题。

---

## OpenAI Chat Completions (`/v1/chat/completions`)

### Ollama 支持的字段

| 字段 | SwiftAISDK 支持 | 实现方式 | 备注 |
|------|----------------|----------|------|
| `model` | ✅ | `LLMRequest.model` | |
| `messages` | ✅ | `LLMRequest.messages` | |
| ├─ Text content | ✅ | `LLMContentBlock.text` | |
| ├─ Image content (base64) | ✅ | `LLMContentBlock.image(.base64)` | |
| ├─ Image content (URL) | ✅ | `LLMContentBlock.image(.url)` | Ollama 文档说不支持 URL，但 SwiftAISDK 会编码 |
| ├─ Array of content parts | ✅ | `encodeUserMessage` 自动展开 | |
| `temperature` | ✅ | `LLMRequest.temperature` | |
| `max_tokens` | ✅ | `LLMRequest.maxOutputTokens` | |
| `top_p` | ⚠️ | `LLMRequest.providerOptions["top_p"]` | 需手动传入 |
| `frequency_penalty` | ⚠️ | `LLMRequest.providerOptions["frequency_penalty"]` | 需手动传入 |
| `presence_penalty` | ⚠️ | `LLMRequest.providerOptions["presence_penalty"]` | 需手动传入 |
| `stop` | ⚠️ | `LLMRequest.providerOptions["stop"]` | 需手动传入 |
| `seed` | ⚠️ | `LLMRequest.providerOptions["seed"]` | 需手动传入 |
| `response_format` | ⚠️ | `LLMRequest.providerOptions["response_format"]` | 需手动传入 |
| `stream` | ✅ | `stream()` vs `complete()` | |
| `stream_options.include_usage` | ⚠️ | `LLMRequest.providerOptions["stream_options"]` | 需手动传入 |
| `tools` | ✅ | `LLMRequest.tools` | |
| `tool_choice` | ✅ | `LLMRequest.toolChoice` | **Ollama 不支持**，会被忽略 |
| `reasoning_effort` | ⚠️ | `LLMRequest.providerOptions["reasoning_effort"]` | 需手动传入 |
| `reasoning.effort` | ⚠️ | `LLMRequest.providerOptions["reasoning"]` | 需手动传入 |

### Ollama **不支持**的字段（SwiftAISDK 也未实现）

- `logit_bias` — 无对应字段
- `user` — 无对应字段
- `n` — 无对应字段（生成多个候选）

### 结论

✅ **完全兼容**。SwiftAISDK 的 `OpenAIChatCompletionsClient` 可以直接对接 Ollama 的 `/v1/chat/completions`。

**使用示例：**

```swift
let client = OpenAIChatCompletionsClient(
    baseURL: URL(string: "http://localhost:11434/v1")!,
    apiKey: "ollama"  // Ollama 要求但不验证
)

let request = LLMRequest(
    model: "qwen3-coder",
    messages: [.user("Hello")],
    temperature: 0.7,
    providerOptions: [
        "top_p": .double(0.9),
        "seed": .int(42),
        "stop": .array([.string("\n\n")])
    ]
)

let response = try await client.complete(request)
```

---

## OpenAI Responses API (`/v1/responses`)

### Ollama 支持的字段

| 字段 | SwiftAISDK 支持 | 实现方式 | 备注 |
|------|----------------|----------|------|
| `model` | ✅ | `LLMRequest.model` | |
| `input` | ✅ | `LLMRequest.messages` 自动转换为 typed items | |
| `instructions` | ⚠️ | `LLMRequest.providerOptions["instructions"]` | 需手动传入 |
| `tools` | ✅ | `LLMRequest.tools` | |
| `stream` | ✅ | `stream()` vs `complete()` | |
| `temperature` | ✅ | `LLMRequest.temperature` | |
| `top_p` | ⚠️ | `LLMRequest.providerOptions["top_p"]` | 需手动传入 |
| `max_output_tokens` | ✅ | `LLMRequest.maxOutputTokens` | |
| `previous_response_id` | ❌ | 无 | **Ollama 不支持 stateful requests** |
| `conversation` | ❌ | 无 | **Ollama 不支持 stateful requests** |
| `truncation` | ❌ | 无 | Ollama 不支持 |

### 结论

✅ **兼容 Ollama 的非状态化 Responses API**。

**注意：** Ollama 文档明确说明不支持 `previous_response_id` 和 `conversation`（stateful requests）。SwiftAISDK 的 `OpenAIResponsesClient` 实现了完整的 OpenAI Responses API（包括 `previous_response_id` 和 `encrypted_content` 的 round-trip），但这些功能在 Ollama 上不可用。

**使用示例：**

```swift
let client = OpenAIResponsesClient(
    baseURL: URL(string: "http://localhost:11434/v1")!,
    apiKey: "ollama",
    includeEncryptedReasoning: false  // Ollama 可能不支持
)

let request = LLMRequest(
    model: "qwen3:8b",
    messages: [.user("Write a poem")],
    providerOptions: [
        "instructions": .string("Be creative")
    ]
)

let response = try await client.complete(request)
```

---

## Anthropic Messages API (`/v1/messages`)

### Ollama 支持的字段

| 字段 | SwiftAISDK 支持 | 实现方式 | 备注 |
|------|----------------|----------|------|
| `model` | ✅ | `LLMRequest.model` | |
| `max_tokens` | ✅ | `LLMRequest.maxOutputTokens` (fallback: `defaultMaxTokens`) | |
| `messages` | ✅ | `LLMRequest.messages` | |
| ├─ Text content | ✅ | `LLMContentBlock.text` | |
| ├─ Image content (base64) | ✅ | `LLMContentBlock.image(.base64)` | |
| ├─ Image content (URL) | ✅ | `LLMContentBlock.image(.url)` | Ollama 文档说不支持 URL |
| ├─ `tool_use` blocks | ✅ | `LLMContentBlock.toolUse` | |
| ├─ `tool_result` blocks | ✅ | `LLMContentBlock.toolResult` | |
| ├─ `thinking` blocks | ✅ | `LLMContentBlock.reasoning` (含 `signature`) | |
| `system` | ✅ | `LLMMessage.system` 自动提取并拼接 | |
| `stream` | ✅ | `stream()` vs `complete()` | |
| `temperature` | ✅ | `LLMRequest.temperature` | |
| `top_p` | ⚠️ | `LLMRequest.providerOptions["top_p"]` | 需手动传入 |
| `top_k` | ⚠️ | `LLMRequest.providerOptions["top_k"]` | 需手动传入 |
| `stop_sequences` | ⚠️ | `LLMRequest.providerOptions["stop_sequences"]` | 需手动传入 |
| `tools` | ✅ | `LLMRequest.tools` | |
| `thinking` | ✅ | `AnthropicMessagesClient.thinkingBudgetTokens` | 构造时传入 |
| `tool_choice` | ✅ | `LLMRequest.toolChoice` | **Ollama 不支持**，会被忽略 |
| `metadata` | ❌ | 无 | Ollama 不支持 |

### Ollama **不支持**的功能（SwiftAISDK 也未实现）

- `/v1/messages/count_tokens` — 无对应方法
- Prompt caching (`cache_control`) — 无对应字段
- Batches API — 无对应方法
- Citations content blocks — 无对应 `LLMContentBlock` case
- PDF support (`document` content blocks) — 无对应 `LLMContentBlock` case
- Server-sent `error` events during streaming — 当前实现会抛出异常而非继续流

### 结论

✅ **完全兼容**。SwiftAISDK 的 `AnthropicMessagesClient` 可以直接对接 Ollama 的 `/v1/messages`。

**使用示例：**

```swift
let client = AnthropicMessagesClient(
    baseURL: URL(string: "http://localhost:11434")!,
    apiKey: "ollama",  // Ollama 要求但不验证
    thinkingBudgetTokens: 10_000  // 启用 extended thinking
)

let request = LLMRequest(
    model: "qwen3-coder",
    messages: [
        .system("You are a helpful assistant"),
        .user("Explain recursion")
    ],
    tools: [myTool],
    toolChoice: .auto,  // Ollama 会忽略
    providerOptions: [
        "top_k": .int(40),
        "stop_sequences": .array([.string("END")])
    ]
)

let response = try await client.complete(request)
```

---

## 关键差异总结

### 1. **`providerOptions` 是扩展点**

SwiftAISDK 的 `LLMRequest.providerOptions` 是一个 `[String: LLMOptionValue]` 字典，用于传递不在核心字段中的参数（如 `top_p`、`seed`、`stop`、`reasoning_effort` 等）。这些参数会被客户端编码器直接合并到请求 JSON 中。

**优点：** 灵活，不需要为每个 provider-specific 参数添加新字段。

**缺点：** 类型不安全，需要手动查文档确认参数名和类型。

### 2. **Ollama 不支持的字段会被忽略或拒绝**

- `tool_choice` — Ollama 文档明确标注为不支持。SwiftAISDK 会编码并发送，但 Ollama 会忽略或返回错误。
- `logit_bias`、`user`、`n` — SwiftAISDK 未实现，Ollama 也不支持。

### 3. **Stateful Responses API 不可用**

Ollama 的 `/v1/responses` 不支持 `previous_response_id` 和 `conversation`。SwiftAISDK 的 `OpenAIResponsesClient` 实现了这些功能（用于 OpenAI 官方 API），但在 Ollama 上无法使用。

### 4. **Extended thinking 的 `budget_tokens` 不强制**

Ollama 文档说 `budget_tokens` 会被接受但不强制执行。SwiftAISDK 的 `AnthropicMessagesClient.thinkingBudgetTokens` 会正确编码该字段，但 Ollama 可能不会严格遵守。

### 5. **Image URL vs Base64**

Ollama 文档说只支持 base64 图片，不支持 URL。SwiftAISDK 两者都会编码，但 Ollama 可能拒绝 URL 形式。

---

## 推荐用法

### 对接 Ollama 的最佳实践

1. **使用 `baseURL` 指向 Ollama**：
   ```swift
   let client = OpenAIChatCompletionsClient(
       baseURL: URL(string: "http://localhost:11434/v1")!,
       apiKey: "ollama"
   )
   ```

2. **通过 `providerOptions` 传递额外参数**：
   ```swift
   let request = LLMRequest(
       model: "qwen3-coder",
       messages: [.user("Hello")],
       providerOptions: [
           "top_p": .double(0.9),
           "seed": .int(42),
           "reasoning_effort": .string("high")
       ]
   )
   ```

3. **避免使用 Ollama 不支持的字段**：
   - 不要设置 `toolChoice`（除非是 `.auto`，这是默认值）
   - 不要在 `OpenAIResponsesClient` 中使用 `previous_response_id`

4. **图片只用 base64**：
   ```swift
   let image = LLMImage(source: .base64("image/png", base64Data))
   ```

---

## 需要改进的地方

### 1. **为常用参数添加一级字段**

当前 `top_p`、`seed`、`stop` 等常用参数需要通过 `providerOptions` 传递，不够直观。可以考虑在 `LLMRequest` 中添加：

```swift
public struct LLMRequest: Sendable {
    // ...
    public let topP: Double?
    public let frequencyPenalty: Double?
    public let presencePenalty: Double?
    public let seed: Int?
    public let stop: [String]?
    public let responseFormat: ResponseFormat?
}
```

**权衡：** 增加字段会让 `LLMRequest` 变得臃肿，且不同 provider 支持的参数不同。当前的 `providerOptions` 设计更灵活。

### 2. **文档中明确 Ollama 兼容性**

在 README 中添加 Ollama 使用示例，说明：
- 如何设置 `baseURL`
- 哪些字段通过 `providerOptions` 传递
- Ollama 的限制（不支持 `tool_choice`、stateful Responses 等）

### 3. **为 Ollama 添加便利构造器**

```swift
extension OpenAIChatCompletionsClient {
    public static func ollama(
        host: String = "http://localhost:11434",
        timeout: TimeInterval = 120
    ) -> Self {
        Self(
            baseURL: URL(string: "\(host)/v1")!,
            apiKey: "ollama",
            timeout: timeout
        )
    }
}

extension AnthropicMessagesClient {
    public static func ollama(
        host: String = "http://localhost:11434",
        thinkingBudgetTokens: Int = 0,
        timeout: TimeInterval = 120
    ) -> Self {
        Self(
            baseURL: URL(string: host)!,
            apiKey: "ollama",
            timeout: timeout,
            thinkingBudgetTokens: thinkingBudgetTokens
        )
    }
}
```

---

## 结论

✅ **SwiftAISDK 已经完全兼容 Ollama**，无需修改代码。

唯一需要做的是：
1. 在文档中添加 Ollama 使用示例
2. （可选）添加便利构造器 `.ollama()`
3. （可选）为常用参数添加一级字段，避免过度依赖 `providerOptions`

当前实现已经覆盖了 Ollama 支持的所有核心功能（messages、streaming、tools、vision、thinking），且因为实现的是上游协议，自动兼容 Ollama 的兼容层。
