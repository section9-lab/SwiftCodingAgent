<div align="center">
<img src="public/SwiftHarnessAgent.png" alt="SwiftHarnessAgent icon" width="120" height="120">
<h1 align="center">SwiftHarnessAgent</h1>
<p align="center">
    A Swift agent runtime for embedding coding agents into macOS and iOS apps.
</p>

[![Swift 5.10](https://img.shields.io/badge/Swift-5.10+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2013+%20%7C%20iOS%2017+-blue.svg)](https://developer.apple.com)
[![SwiftPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/section9-lab/SwiftHarnessAgent?style=social)](https://github.com/section9-lab/SwiftHarnessAgent/stargazers)

</div>

A multi-step agent loop, sandboxed file & shell tools, skill loading, and context compaction — with first-class OpenAI and Anthropic backends. Mirrors the Anthropic / oh-my-pi tool conventions (`read`, `edit`, `bash`, `todo_write`, `ask`, `task` subagents) so prompts and skills port cleanly between harnesses.

Not an OpenAI SDK wrapper. If you want `client.chat(...)`, use a thinner library. If you want a coding agent that reads files, edits code, and runs shell commands under your policy — keep reading.

```swift
import SwiftHarnessAgent

let workspace = URL(fileURLWithPath: ".")

let agent = AgentSDK(
    client: EchoClient(),                               // swap with OpenAIChatCompletionsClient / AnthropicMessagesClient
    modelName: "echo",
    workingDirectory: workspace,
    executionPolicy: ToolExecutionPolicy(workingDirectory: workspace)
)

let result = try await agent.run(prompt: "Read README.md and summarize")
print(result.finalText)
```

## Architecture

SwiftHarnessAgent is a **monorepo** containing two Swift Package Manager products:

- **`SwiftAISDK`** — provider-agnostic LLM client layer. Use this directly if you only want OpenAI / Anthropic API access without the agent runtime.
- **`SwiftHarnessAgent`** — coding-agent runtime built on top of SwiftAISDK. Includes the multi-step loop, tools, skills, subagents, and compaction.

Both products live in the same `Package.swift` and share a single `Package.resolved`, following the pattern used by `swift-collections` and `swift-async-algorithms`.

### SwiftAISDK

Provider-agnostic LLM client with rich content-block support:

- **`LLMClient` protocol** — implement for any backend
- **`LLMMessage`** — role + array of typed content blocks (text, image, reasoning, toolUse, toolResult, refusal)
- **`LLMContentBlock`** — preserves reasoning signatures (Anthropic extended thinking), encrypted reasoning (OpenAI Responses), and tool-use metadata across turns
- **Built-in clients:**
  - `EchoClient` — local stub, no API key needed
  - `OpenAIChatCompletionsClient` — `/v1/chat/completions` (OpenAI, NVIDIA NIM, vLLM, Ollama, Together, Groq, etc.)
  - `OpenAIResponsesClient` — `/v1/responses` (OpenAI's newer protocol with reasoning persistence and server-side state)
  - `AnthropicMessagesClient` — `/v1/messages` with extended thinking + signature round-tripping

The SDK's content-block model is **lossless** — reasoning blocks with signatures (required for Anthropic extended-thinking + tool-use multi-turn correctness) and encrypted reasoning (OpenAI Responses) are preserved verbatim across turns.

### SwiftHarnessAgent

Coding-agent runtime:

- `AgentSDK` — main entry, assembles client + tools + policy + skills + compaction
- `AgentLoop` — the multi-step reasoning loop
- `ToolExecutionPolicy` — file allow-roots and bash sandboxing (disabled / sandboxed / unrestricted)
- `ReadTool` / `WriteTool` / `EditTool` / `BashTool`
- `TodoStore` + `TodoWriteTool` — phased task tracking with a live `phasesStream()`
- `AskTool` — interactive user prompts via an `AskHandler` closure
- `TaskCoordinator` + `SubagentDefinition` — parallel subagent fan-out
- `SkillLoader` — load `SKILL.md` directories into reusable skill definitions
- `CompactionConfig` — summarize older context to keep long histories bounded

## Quick Start

**1. Add the package** to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/section9-lab/SwiftHarnessAgent", from: "1.0.0")
]
```

**2. Add the product** to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "SwiftHarnessAgent", package: "SwiftHarnessAgent")
        // or .product(name: "SwiftAISDK", package: "SwiftHarnessAgent") for client-only
    ]
)
```

**3. Run the snippet above** — `EchoClient` needs no API key, so the agent boots immediately. Swap it for a real backend when you are ready (see [Recipes](#recipes)).

## How it differs

### vs [`SwiftAgent`](https://github.com/1amageek/SwiftAgent) (1amageek)

**SwiftAgent** is a SwiftUI-style declarative DSL for composing LLM workflows on top of Apple's FoundationModels. You describe pipelines as `Step` values inside a `body` and the framework synthesizes `run(_:)`.

**SwiftHarnessAgent** is a coding-agent *runtime* — a multi-step loop with built-in file/edit/bash tools, sandboxing, skill loading, subagents, and context compaction.

| You want to... | Use |
|---|---|
| Compose declarative LLM pipelines (`Transform` / `Map` / `Race` / `Gate`) | SwiftAgent |
| Ship on iOS 26 / macOS 26 with Apple FoundationModels first | SwiftAgent |
| Embed a coding agent that reads & edits files and runs shell commands | **SwiftHarnessAgent** |
| Target OpenAI or Anthropic as a first-class backend | **SwiftHarnessAgent** |
| Ship today on iOS 17 / macOS 13, Swift 5.10 | **SwiftHarnessAgent** |
| Reuse Anthropic / oh-my-pi tool conventions (skills, todos, subagents) | **SwiftHarnessAgent** |

The two are not really competitors — SwiftAgent treats LLMs as a declarative computation primitive; SwiftHarnessAgent treats them as the brain of an autonomous tool-using agent.

## Recipes

### OpenAI Chat Completions (and compatible endpoints)

```swift
let client = OpenAIChatCompletionsClient(
    baseURL: URL(string: "https://api.openai.com/v1")!,
    apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
)

let agent = AgentSDK(
    client: client,
    modelName: "gpt-4o",
    workingDirectory: workspace,
    executionPolicy: ToolExecutionPolicy(
        workingDirectory: workspace,
        bash: .disabled
    ),
    maxSteps: 8
)
```

Works with OpenAI, NVIDIA NIM, vLLM, sglang, Ollama's OpenAI shim, Together, Groq, and any other `/v1/chat/completions` endpoint.

### OpenAI Responses API (with reasoning persistence)

```swift
let client = OpenAIResponsesClient(
    baseURL: URL(string: "https://api.openai.com/v1")!,
    apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
    includeEncryptedReasoning: true
)

let agent = AgentSDK(
    client: client,
    modelName: "gpt-5.2",
    workingDirectory: workspace,
    executionPolicy: ToolExecutionPolicy(workingDirectory: workspace)
)
```

The Responses API is OpenAI's newer protocol with reasoning persistence and server-side state. Set `includeEncryptedReasoning: true` to thread reasoning across turns (required for o1 / o3 / gpt-5 style models when you want reasoning continuity).

### Anthropic Messages API (with extended thinking)

```swift
let client = AnthropicMessagesClient(
    apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
    thinkingBudgetTokens: 10_000  // enable extended thinking with 10k token budget
)

let agent = AgentSDK(
    client: client,
    modelName: "claude-sonnet-4-6",
    workingDirectory: workspace,
    executionPolicy: ToolExecutionPolicy(workingDirectory: workspace, bash: .disabled)
)
```

Extended thinking blocks with signatures are automatically preserved across turns (required for Anthropic extended-thinking + tool-use multi-turn correctness).

### Custom tool

```swift
struct CurrentTimeTool: AgentTool {
    let name = "current_time"
    let description = "Returns the current local time"
    let argumentSchemaJSON = #"{"type":"object","properties":{}}"#

    func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        Date().formatted(date: .omitted, time: .standard)
    }
}

let agent = AgentSDK(
    client: client,
    modelName: "gpt-4o",
    tools: [CurrentTimeTool()],
    workingDirectory: workspace,
    executionPolicy: ToolExecutionPolicy(workingDirectory: workspace)
)
```

### Skills from disk

```swift
let agent = AgentSDK(
    client: client,
    modelName: "gpt-4o",
    workingDirectory: workspace,
    executionPolicy: ToolExecutionPolicy(workingDirectory: workspace),
    skillsDirectories: [URL(fileURLWithPath: "/path/to/.skills")]
)
```

### Todos, Ask, and Subagents (oh-my-pi parity)

Three opt-in tools. Each is enabled by passing its dependency to `AgentSDK`; otherwise it stays off and is not advertised to the model.

```swift
// todo_write — phased task tracking
let todoStore = TodoStore()
Task {
    for await phases in await todoStore.phasesStream() {
        print("phases:", phases.map(\.name))   // render to your UI
    }
}

// ask — clarifying questions
let askHandler: AskHandler = { questions in
    questions.map { q in
        AskAnswer(id: q.id, selections: [q.options[q.recommended ?? 0]])
    }
}

// task — parallel subagents
let explorer = SubagentDefinition(
    id: "explore",
    displayName: "Explorer",
    description: "Read-only investigator that returns compressed context",
    systemPrompt: "You are a read-only codebase scout. Return concise findings.",
    tools: [ReadTool()],
    maxSteps: 8
)

let coordinator = TaskCoordinator(
    definitions: [explorer],
    clientFactory: { _ in
        (
            OpenAIChatCompletionsClient(
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ),
            "gpt-4o-mini"
        )
    },
    workingDirectory: workspace,
    executionPolicy: ToolExecutionPolicy(workingDirectory: workspace),
    maxConcurrency: 4
)

let agent = AgentSDK(
    client: client,
    modelName: "gpt-4o",
    workingDirectory: workspace,
    executionPolicy: ToolExecutionPolicy(workingDirectory: workspace),
    todoStore: todoStore,
    askHandler: askHandler,
    taskCoordinator: coordinator
)
```

Subagents inherit the parent's working directory and execution policy. Each task carries its own `assignment`; an optional `context` is shared across the batch. A failure in one task does not abort the rest — it is reported as a `failed` result.

## Core Concepts

- **`AgentSDK`** — assembles the client, model name, tools, skills, execution policy, working directory, and compaction settings into a runnable agent.
- **`LLMClient`** — implement for your own backend, or use `OpenAIChatCompletionsClient` / `OpenAIResponsesClient` / `AnthropicMessagesClient` / `EchoClient`.
- **Tools** — implement `AgentTool` to expose capabilities. Every tool runs with a `ToolExecutionContext` carrying the working directory and the effective execution policy.
- **`ToolExecutionPolicy`** — separates file access (scoped via allowed roots) from shell execution (`disabled`, sandboxed via `sandbox-exec`, or unrestricted). `read` caps file size by default to keep tool output from blowing past the model's context window.
- **`SkillLoader`** — scans directories for `SKILL.md` files and turns them into reusable skill definitions injected into the agent.
- **`CompactionConfig`** — summarize older turns before context grows out of bounds, so long-running conversations stay tractable.


### Parallel Tool Calls (Barrier Scheduler)

When `parallelToolCalls: true` is set in `AgentLoopConfig`, the agent loop uses a barrier-based scheduler inspired by oh-my-pi:

- **`.shared` tools** (default — `read`, `search`, `find`, `ast_grep`) run concurrently within a batch.
- **`.exclusive` tools** (`write`, `edit`, `bash`, `todo_write`) act as barriers: the pending shared batch drains first, then the exclusive tool runs alone, then accumulation resumes.
- **Results** always return in the original tool_use order.

```swift
let config = AgentLoopConfig(
    workingDirectory: workspace,
    parallelToolCalls: true  // Enable barrier scheduler
)
```

Custom tools opt into the right mode via the `concurrency` property:

```swift
struct MyReadOnlyTool: AgentTool {
    // ...
    var concurrency: ToolConcurrency { .shared }    // default, can omit
}

struct MyWriteTool: AgentTool {
    // ...
    var concurrency: ToolConcurrency { .exclusive } // serialized
}
```
## Non-Goals

- **Not a UI framework.** Bring your own SwiftUI / AppKit / UIKit layer — `TodoStore.phasesStream()` and `AskHandler` exist precisely so the runtime stays headless.
- **Not a single-shot LLM SDK.** For `client.chat(...)`-style calls, a thinner library will serve you better (or use `SwiftAISDK` directly).
- **Not a declarative DSL.** If you want `body { Transform; GenerateText; ... }`, see [SwiftAgent](https://github.com/1amageek/SwiftAgent).
- **`bash` is macOS-only** (uses `sandbox-exec`). On other platforms it raises an explicit error rather than silently downgrading sandboxing.

## Testing

```bash
swift test
swift run SwiftHarnessAgentExample
```

All 67 tests pass.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=section9-lab/SwiftHarnessAgent&type=Date)](https://star-history.com/#section9-lab/SwiftHarnessAgent&Date)

## License

MIT — see [LICENSE](LICENSE).
