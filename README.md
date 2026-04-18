# SwiftAgent

A Swift Package for building AI agents with tool-calling capabilities.

## Overview

SwiftAgent provides:

- **AgentModel protocol** - Interface for LLM backends (OpenAI-compatible, custom)
- **AgentTool protocol** - Extensible tool system
- **AgentLoop** - Core agent execution loop with compaction support
- **AgentSkill** - Skill injection system
- **Built-in tools** - `read`, `write`, `edit`, `bash`

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/YOUR_USERNAME/SwiftAgent.git", from: "1.0.0")
]
```

## Quick Start

```swift
import SwiftAgent

// Use EchoModel for testing (no API key needed)
let model = EchoModel()

// Or use OpenAI-compatible models
let openAI = OpenAICompatibleChatModel(
    baseURL: URL(string: "https://api.openai.com/v1")!,
    apiKey: "your-api-key",
    modelName: "gpt-4o"
)

// Create agent
let agent = AgentSDK(
    model: openAI,
    workingDirectory: URL(fileURLWithPath: "/path/to/workspace"),
    executionPolicy: ToolExecutionPolicy(
        workingDirectory: URL(fileURLWithPath: "/path/to/workspace"),
        allowedRoots: [URL(fileURLWithPath: "/path/to/shared")],
        bash: .disabled
    ),
    maxSteps: 10
)

// Run
let result = try await agent.run(prompt: "Read README.md and summarize it")
print(result.finalText)
```

## Tools

### Built-in Tools

- `ReadTool` - Read text files
- `WriteTool` - Write/create files
- `EditTool` - Find and replace in files
- `BashTool` - Execute shell commands using an explicit execution policy

### Execution Policy

`read`, `write`, and `edit` always respect the configured file roots. `bash` is configured separately so apps can disable it, run it in a constrained sandbox, or allow unrestricted execution.

```swift
let policy = ToolExecutionPolicy(
    workingDirectory: workspaceURL,
    allowedRoots: [workspaceURL, sharedToolsURL],
    bash: .sandboxed(.init())
)

let agent = AgentSDK(
    model: model,
    workingDirectory: workspaceURL,
    executionPolicy: policy
)
```

### Custom Tools

```swift
struct MyTool: AgentTool {
    let name = "my_tool"
    let description = "Does something useful"
    let argumentSchemaJSON = #"{"type":"object","properties":{"input":{"type":"string"}},"required":["input"]}"#
    
    func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        // Parse args, do work, return result
        return "Tool output"
    }
}
```

## Skills

Skills provide system prompts and additional tools:

```swift
let skill = BasicSkill(
    name: "code-reviewer",
    systemPrompt: "You are a code reviewer...",
    tools: []
)

let agent = AgentSDK(model: model, skills: [skill], ...)
```

Or load from directory (SKILL.md format):

```swift
let skills = SkillLoader.loadSkills(from: skillsDirectory)
```

## Compaction

Long conversations are automatically compacted to stay within context limits:

```swift
let compaction = CompactionConfig(
    enabled: true,
    modelContextWindow: 128_000,
    reserveTokens: 16_384,
    keepRecentTokens: 20_000
)

let agent = AgentSDK(model: model, compaction: compaction, ...)
```

## License

MIT
