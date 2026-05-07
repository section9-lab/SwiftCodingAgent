<div align="center">
<img src="public/SwiftHarnessAgent.png" alt="SwiftHarnessAgent icon" width="120" height="120">
<h1 align="center">SwiftHarnessAgent</h1>
<p align="center">
    A native Swift package for building tool-using coding agents.
</p>
<p align="center">
SwiftHarnessAgent gives you the core pieces needed to build an agent runtime in Swift: model adapters, a multi-step agent loop, skill loading, built-in tools, and explicit execution boundaries for file access and shell commands.

It is designed for apps that need real agent behavior instead of a thin chat wrapper. One example is Loggo, which uses SwiftHarnessAgent as its agent foundation.
</p>

[![GitHub Star](https://img.shields.io/github/stars/section9-lab/SwiftHarnessAgent?style=rounded&color=white&labelColor=000000)](https://github.com/section9-lab/SwiftHarnessAgent/stargazers)
[![GitHub license](https://img.shields.io/github/license/section9-lab/SwiftHarnessAgent?style=rounded&color=white&labelColor=000000)](LICENSE)

</div>

## Why SwiftHarnessAgent

SwiftHarnessAgent is built for Swift apps that want to embed an agent without pushing the whole runtime into another language.

Instead of wiring prompts, tool schemas, execution guards, message history, and context compaction from scratch, you get a focused package that already handles the agent loop and the operational boundaries around it.

It is especially useful when you want to:

- build local-first or native Apple platform agent experiences
- expose file and shell tools with explicit policy control
- load reusable skills from disk
- support long-running conversations without unbounded context growth
- swap between test models and OpenAI-compatible backends

## Product Features

### Native Swift agent runtime
Build and run agents directly in Swift with `AgentSDK`, `AgentLoop`, and a small set of composable protocols.

### OpenAI-compatible model integration
Plug in any backend that speaks the OpenAI Chat Completions format with `OpenAICompatibleChatModel`, talk to Anthropic directly with `AnthropicChatModel`, or use `EchoModel` for local testing.

### Built-in tool system
The package includes `read`, `write`, `edit`, and `bash` tools, plus the `AgentTool` protocol for adding your own tools. `read` caps file size by default to keep tool output from blowing past the model's context window. `bash` is macOS-only (uses `sandbox-exec`); on other platforms it raises an explicit error.

### Explicit execution boundaries
File access and shell execution are controlled through `ToolExecutionPolicy`, so apps can decide exactly what an agent is allowed to touch.

### Skill loading from disk
Load skills from SKILL.md directories with `SkillLoader`, making it easier to package reusable prompts and capabilities.

### Long-context support through compaction
`CompactionConfig` helps keep long conversations manageable by summarizing older context before it grows out of bounds.

## System Requirements

- Swift 5.10+
- macOS 13+ or iOS 17+

## Installation

Add SwiftHarnessAgent with Swift Package Manager:

```swift
dependencies: [
    .package(path: "../SwiftHarnessAgent")
]
```

Or add it from your Git host in the usual SwiftPM form:

```swift
dependencies: [
    .package(url: "<your-repository-url>", from: "1.0.0")
]
```

Then add the product to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "SwiftHarnessAgent", package: "SwiftHarnessAgent")
    ]
)
```

## Quick Start

```swift
import Foundation
import SwiftHarnessAgent

let workspaceURL = URL(fileURLWithPath: "/path/to/workspace")

let model = OpenAICompatibleChatModel(
    baseURL: URL(string: "https://api.openai.com/v1")!,
    apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
    modelName: "gpt-4o"
)

let agent = AgentSDK(
    model: model,
    workingDirectory: workspaceURL,
    executionPolicy: ToolExecutionPolicy(
        workingDirectory: workspaceURL,
        bash: .disabled
    ),
    maxSteps: 8
)

let result = try await agent.run(
    prompt: "Read README.md and summarize the project"
)

print(result.finalText)
```

To use Anthropic's Claude models directly via the Messages API:

```swift
let model = AnthropicChatModel(
    apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
    modelName: "claude-sonnet-4-5"
)

let agent = AgentSDK(
    model: model,
    workingDirectory: workspaceURL,
    executionPolicy: ToolExecutionPolicy(
        workingDirectory: workspaceURL,
        bash: .disabled
    )
)
```

For local smoke testing without any API key:

```swift
let agent = AgentSDK(
    model: EchoModel(),
    workingDirectory: workspaceURL,
    executionPolicy: ToolExecutionPolicy(
        workingDirectory: workspaceURL,
        bash: .disabled
    )
)
```

## Core Concepts

### AgentSDK
`AgentSDK` is the main entry point. It assembles the model, tools, skills, execution policy, working directory, and compaction settings into a runnable agent.

### Models
Implement `AgentModel` to connect your own backend, use `OpenAICompatibleChatModel` for providers that expose the OpenAI-compatible chat API shape, or use `AnthropicChatModel` for Anthropic's Messages API (with native `tool_use` / `tool_result` support).

### Tools
Implement `AgentTool` to expose capabilities. Every tool runs with a `ToolExecutionContext`, which includes the working directory and the effective execution policy.

### Execution Policy
`ToolExecutionPolicy` separates file access from shell execution:

- file access is scoped through allowed roots
- bash can be disabled, sandboxed, or unrestricted

That gives app developers a straightforward way to keep agent power inside clear boundaries.

### Skills
`SkillLoader` scans directories for `SKILL.md` files and turns them into reusable skill definitions that can be injected into the agent.

### Compaction
Use `CompactionConfig` when you need the agent to handle longer histories without sending the full conversation every time.

## Custom Tool Example

```swift
import Foundation
import SwiftHarnessAgent

struct CurrentTimeTool: AgentTool {
    let name = "current_time"
    let description = "Returns the current local time"
    let argumentSchemaJSON = #"{"type":"object","properties":{}}"#

    func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        Date().formatted(date: .omitted, time: .standard)
    }
}
```

Register it when creating the agent:

```swift
let agent = AgentSDK(
    model: model,
    tools: [CurrentTimeTool()],
    workingDirectory: workspaceURL,
    executionPolicy: ToolExecutionPolicy(workingDirectory: workspaceURL)
)
```

## Skill Loading Example

```swift
let skillsDirectory = URL(fileURLWithPath: "/path/to/.skills")

let agent = AgentSDK(
    model: model,
    workingDirectory: workspaceURL,
    executionPolicy: ToolExecutionPolicy(workingDirectory: workspaceURL),
    skillsDirectories: [skillsDirectory]
)
```

## Testing

Run the test suite with:

```bash
swift test
```

Run the example executable with:

```bash
swift run SwiftHarnessAgentExample
```

## License

MIT
