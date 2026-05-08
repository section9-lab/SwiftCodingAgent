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
    model: EchoModel(),                                 // swap with OpenAICompatibleChatModel / AnthropicChatModel
    workingDirectory: workspace,
    executionPolicy: ToolExecutionPolicy(workingDirectory: workspace)
)

let result = try await agent.run(prompt: "Read README.md and summarize")
print(result.finalText)
```

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
    ]
)
```

**3. Run the snippet above** — `EchoModel` needs no API key, so the agent boots immediately. Swap it for a real backend when you are ready (see [Recipes](#recipes)).

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

## What's in the box

- `AgentSDK` — main entry, assembles model + tools + policy + skills + compaction
- `AgentLoop` — the multi-step reasoning loop
- `AgentModel` protocol — implement for any backend
- `OpenAICompatibleChatModel` / `AnthropicChatModel` / `EchoModel`
- `ToolExecutionPolicy` — file allow-roots and bash sandboxing (disabled / sandboxed / unrestricted)
- `ReadTool` / `WriteTool` / `EditTool` / `BashTool`
- `TodoStore` + `TodoWriteTool` — phased task tracking with a live `phasesStream()`
- `AskTool` — interactive user prompts via an `AskHandler` closure
- `TaskCoordinator` + `SubagentDefinition` — parallel subagent fan-out
- `SkillLoader` — load `SKILL.md` directories into reusable skill definitions
- `CompactionConfig` — summarize older context to keep long histories bounded

## Recipes

### OpenAI-compatible backends

```swift
let model = OpenAICompatibleChatModel(
    baseURL: URL(string: "https://api.openai.com/v1")!,
    apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
    modelName: "gpt-4o"
)

let agent = AgentSDK(
    model: model,
    workingDirectory: workspace,
    executionPolicy: ToolExecutionPolicy(
        workingDirectory: workspace,
        bash: .disabled
    ),
    maxSteps: 8
)
```

### Anthropic (native Messages API with `tool_use` / `tool_result`)

```swift
let model = AnthropicChatModel(
    apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
    modelName: "claude-sonnet-4-5"
)

let agent = AgentSDK(
    model: model,
    workingDirectory: workspace,
    executionPolicy: ToolExecutionPolicy(workingDirectory: workspace, bash: .disabled)
)
```

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
    model: model,
    tools: [CurrentTimeTool()],
    workingDirectory: workspace,
    executionPolicy: ToolExecutionPolicy(workingDirectory: workspace)
)
```

### Skills from disk

```swift
let agent = AgentSDK(
    model: model,
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
    modelFactory: { _ in
        OpenAICompatibleChatModel(
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
            modelName: "gpt-4o-mini"
        )
    },
    workingDirectory: workspace,
    executionPolicy: ToolExecutionPolicy(workingDirectory: workspace),
    maxConcurrency: 4
)

let agent = AgentSDK(
    model: model,
    workingDirectory: workspace,
    executionPolicy: ToolExecutionPolicy(workingDirectory: workspace),
    todoStore: todoStore,
    askHandler: askHandler,
    taskCoordinator: coordinator
)
```

Subagents inherit the parent's working directory and execution policy. Each task carries its own `assignment`; an optional `context` is shared across the batch. A failure in one task does not abort the rest — it is reported as a `failed` result.

## Core Concepts

- **`AgentSDK`** — assembles the model, tools, skills, execution policy, working directory, and compaction settings into a runnable agent.
- **Models** — implement `AgentModel` for your own backend, or use `OpenAICompatibleChatModel` / `AnthropicChatModel` / `EchoModel`.
- **Tools** — implement `AgentTool` to expose capabilities. Every tool runs with a `ToolExecutionContext` carrying the working directory and the effective execution policy.
- **`ToolExecutionPolicy`** — separates file access (scoped via allowed roots) from shell execution (`disabled`, sandboxed via `sandbox-exec`, or unrestricted). `read` caps file size by default to keep tool output from blowing past the model's context window.
- **`SkillLoader`** — scans directories for `SKILL.md` files and turns them into reusable skill definitions injected into the agent.
- **`CompactionConfig`** — summarize older turns before context grows out of bounds, so long-running conversations stay tractable.

## Non-Goals

- **Not a UI framework.** Bring your own SwiftUI / AppKit / UIKit layer — `TodoStore.phasesStream()` and `AskHandler` exist precisely so the runtime stays headless.
- **Not a single-shot LLM SDK.** For `client.chat(...)`-style calls, a thinner library will serve you better.
- **Not a declarative DSL.** If you want `body { Transform; GenerateText; ... }`, see [SwiftAgent](https://github.com/1amageek/SwiftAgent).
- **`bash` is macOS-only** (uses `sandbox-exec`). On other platforms it raises an explicit error rather than silently downgrading sandboxing.

## Testing

```bash
swift test
swift run SwiftHarnessAgentExample
```

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=section9-lab/SwiftHarnessAgent&type=Date)](https://star-history.com/#section9-lab/SwiftHarnessAgent&Date)

## License

MIT — see [LICENSE](LICENSE).
