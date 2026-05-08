# 并发工具调度实现总结

## 实现内容

为 SwiftHarnessAgent 实现了 oh-my-pi 风格的 barrier 调度器，支持工具并发执行。

## 核心改动

### 1. 工具并发声明 (`Sources/SwiftHarnessAgent/Tools/Core/AgentTool.swift`)

添加了 `ToolConcurrency` 枚举和协议字段：

```swift
public enum ToolConcurrency: String, Sendable {
    case shared     // 可与其他 shared 工具并行
    case exclusive  // 独占执行，其他工具必须等待
}

public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var argumentSchemaJSON: String { get }
    var concurrency: ToolConcurrency { get }  // 新增
    
    func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String
}

// 默认实现：大多数工具是只读的，可以安全并行
extension AgentTool {
    public var concurrency: ToolConcurrency { .shared }
}
```

### 2. 标记 exclusive 工具

为写入类工具标记为 `.exclusive`：

- `WriteTool` — 文件写入
- `EditTool` — 文件编辑
- `BashTool` — Shell 命令执行
- `TodoWriteTool` — TODO 列表修改

其他工具（`ReadTool`、`SearchTool`、`FindTool` 等）保持默认 `.shared`。

### 3. Barrier 调度器 (`Sources/SwiftHarnessAgent/Runtime/AgentLoop.swift`)

重写 `runToolCalls` 方法实现 barrier 语义：

```swift
private func runToolCalls(_ uses: [LLMToolUse]) async throws -> [LLMToolResult] {
    guard config.parallelToolCalls && uses.count > 1 else {
        return try await runSequentially(uses)
    }
    
    // 预先解析每个工具的 concurrency
    var concurrencies: [ToolConcurrency] = []
    for use in uses {
        concurrencies.append(await toolRegistry.concurrency(for: use.name))
    }
    
    var results: [LLMToolResult?] = Array(repeating: nil, count: uses.count)
    var sharedBatch: [(Int, LLMToolUse)] = []
    
    func drainSharedBatch() async {
        guard !sharedBatch.isEmpty else { return }
        // 并行执行 shared batch
        await withTaskGroup(of: (Int, LLMToolResult).self) { group in
            for (index, use) in batch {
                group.addTask {
                    let result = await Self.executeTool(...)
                    return (index, result)
                }
            }
            for await (index, result) in group {
                results[index] = result
            }
        }
    }
    
    for (index, use) in uses.enumerated() {
        switch concurrencies[index] {
        case .shared:
            sharedBatch.append((index, use))
        case .exclusive:
            await drainSharedBatch()  // 先执行累积的 shared batch
            let result = await Self.executeTool(...)  // 独占执行
            results[index] = result
        }
    }
    await drainSharedBatch()  // 执行最后一批
    
    return results.map { $0! }  // 按原始顺序返回
}
```

**关键设计点：**

1. **Barrier 语义**：遇到 exclusive 工具时，先等待所有 shared 工具完成，然后独占执行，再继续累积下一批 shared 工具
2. **结果顺序保证**：用 `[LLMToolResult?]` 数组按索引存储结果，确保返回顺序与 `uses` 一致
3. **向后兼容**：`parallelToolCalls: false`（默认）时，所有工具串行执行

### 4. ToolRegistry 扩展

添加 `concurrency(for:)` 查询方法：

```swift
public func concurrency(for toolName: String) -> ToolConcurrency {
    tools[toolName]?.concurrency ?? .shared
}
```

## 测试覆盖

新增 `Tests/SwiftHarnessAgentTests/Runtime/ToolConcurrencyTests.swift`，包含 6 个测试：

1. **`allSharedToolsRunInParallel`** — 验证 3 个 shared 工具并行执行（~50ms，而非串行的 150ms）
2. **`exclusiveToolActsAsBarrier`** — 验证 exclusive 工具作为屏障：[read, read, write, read, read] 分三段执行
3. **`multipleExclusiveToolsRunSequentially`** — 验证连续的 exclusive 工具串行执行（~90ms）
4. **`resultsReturnInOriginalOrder`** — 验证结果按原始顺序返回（即使 fast 先完成）
5. **`parallelToolCallsDisabledRunsSequentially`** — 验证 `parallelToolCalls: false` 时全部串行
6. **`realToolsConcurrencyDeclarations`** — 验证真实工具的 concurrency 声明正确

**测试结果：** 全部 52 个测试通过（包括新增的 6 个）

## 执行示例

### 场景 1：并发读取多个文件

**LLM 输出：**
```json
[
  {"type": "tool_use", "id": "1", "name": "read", "input": {"path": "README.md"}},
  {"type": "tool_use", "id": "2", "name": "read", "input": {"path": "Package.swift"}},
  {"type": "tool_use", "id": "3", "name": "search", "input": {"pattern": "LLMClient", "paths": ["Sources/"]}}
]
```

**调度器行为：**
```
[read, read, search] 全部是 shared
→ TaskGroup 并行启动 3 个任务
→ 等待所有完成
→ 返回 3 个结果
```

### 场景 2：混合读写

**LLM 输出：**
```json
[
  {"type": "tool_use", "id": "1", "name": "read", "input": {"path": "foo.swift"}},
  {"type": "tool_use", "id": "2", "name": "search", "input": {"pattern": "func", "paths": ["."]}},
  {"type": "tool_use", "id": "3", "name": "edit", "input": {"path": "foo.swift", "edits": [...]}},
  {"type": "tool_use", "id": "4", "name": "read", "input": {"path": "bar.swift"}},
  {"type": "tool_use", "id": "5", "name": "read", "input": {"path": "baz.swift"}}
]
```

**调度器行为：**
```
1. [read, search] 并行执行（shared batch 1）
2. 等待 batch 1 完成
3. [edit] 独占执行（exclusive barrier）
4. 等待 edit 完成
5. [read, read] 并行执行（shared batch 2）
6. 返回所有结果（按原始顺序）
```

### 场景 3：连续写入

**LLM 输出：**
```json
[
  {"type": "tool_use", "id": "1", "name": "write", "input": {"path": "a.swift", "content": "..."}},
  {"type": "tool_use", "id": "2", "name": "write", "input": {"path": "b.swift", "content": "..."}},
  {"type": "tool_use", "id": "3", "name": "bash", "input": {"command": "swift build"}}
]
```

**调度器行为：**
```
1. [write] 独占执行
2. [write] 独占执行
3. [bash] 独占执行
→ 完全串行，避免文件冲突
```

## 关键优势

1. **自动并行化**：LLM 不需要知道并发规则，只管一次输出多个 tool_use，调度器自动优化
2. **安全性**：exclusive 工具串行化，避免竞态条件（如同时写同一文件）
3. **结构化并发**：用 Swift 的 `TaskGroup`，任务取消和错误传播自动处理
4. **零配置**：工具作者只需声明 `concurrency`，调度器自动处理
5. **向后兼容**：默认 `parallelToolCalls: false`，不影响现有代码

## 使用方式

### 启用并发调度

```swift
let config = AgentLoopConfig(
    workingDirectory: workspace,
    parallelToolCalls: true  // 启用 barrier 调度器
)

let agent = AgentSDK(
    client: client,
    modelName: "gpt-4o",
    workingDirectory: workspace,
    executionPolicy: ToolExecutionPolicy(workingDirectory: workspace),
    config: config
)
```

### 自定义工具声明 concurrency

```swift
struct MyReadOnlyTool: AgentTool {
    let name = "my_read_tool"
    let description = "Read-only tool"
    let argumentSchemaJSON = "{}"
    
    // 默认是 .shared，可以省略
    var concurrency: ToolConcurrency { .shared }
    
    func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        // ...
    }
}

struct MyWriteTool: AgentTool {
    let name = "my_write_tool"
    let description = "Write tool"
    let argumentSchemaJSON = "{}"
    
    // 写入工具标记为 .exclusive
    var concurrency: ToolConcurrency { .exclusive }
    
    func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        // ...
    }
}
```

## 文件清单

### 修改的文件

- `Sources/SwiftHarnessAgent/Tools/Core/AgentTool.swift` — 添加 `ToolConcurrency` 枚举和协议字段
- `Sources/SwiftHarnessAgent/Tools/FileSystem/WriteTool.swift` — 标记为 `.exclusive`
- `Sources/SwiftHarnessAgent/Tools/FileSystem/EditTool.swift` — 标记为 `.exclusive`
- `Sources/SwiftHarnessAgent/Tools/Execution/BashTool.swift` — 标记为 `.exclusive`
- `Sources/SwiftHarnessAgent/Tools/Productivity/TodoWriteTool.swift` — 标记为 `.exclusive`
- `Sources/SwiftHarnessAgent/Runtime/AgentLoop.swift` — 实现 barrier 调度逻辑
- `README.md` — 添加并发调度章节，更新测试数量

### 新增的文件

- `Tests/SwiftHarnessAgentTests/Runtime/ToolConcurrencyTests.swift` — 6 个并发调度测试
- `Examples/SwiftHarnessAgentExample/ConcurrencyDemo.swift` — 演示示例（可选）

## 对比 oh-my-pi

| 特性 | oh-my-pi (TypeScript) | SwiftHarnessAgent (Swift) |
|------|----------------------|---------------------------|
| 并发模型 | Promise.allSettled | TaskGroup (结构化并发) |
| Concurrency 字段 | `"shared"` \| `"exclusive"` | `ToolConcurrency` enum |
| Barrier 语义 | ✅ | ✅ |
| 结果顺序保证 | ✅ | ✅ |
| 默认行为 | 并发启用 | 串行（向后兼容） |
| 取消传播 | 手动 | 自动（TaskGroup） |

## 总结

成功实现了 oh-my-pi 风格的 barrier 调度器，支持：

✅ 只读工具（read、search、find）并行执行  
✅ 写入工具（write、edit、bash）作为 barrier 串行化  
✅ 结果按原始顺序返回  
✅ 结构化并发（TaskGroup）自动处理取消和错误  
✅ 向后兼容（默认串行）  
✅ 6 个新测试全部通过，52 个总测试全部通过  
✅ 文档完善（README + 本总结）

这个实现直接对标 oh-my-pi 的 `agent-loop.ts:735-753`，但用 Swift 的结构化并发更安全、更简洁。
