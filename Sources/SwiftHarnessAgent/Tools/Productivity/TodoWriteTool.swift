import Foundation

/// `todo_write` tool. Manages a phased task list inside a `TodoStore`.
/// The textual response is what the model sees — a markdown summary of the
/// updated list — while UI layers can subscribe to `TodoStore.phasesStream`
/// for live updates.
public struct TodoWriteTool: AgentTool {
    public let name = "todo_write"
    public let description: String
    public let argumentSchemaJSON = """
    {"type":"object","properties":{"ops":{"type":"array","minItems":1,"items":{"type":"object","properties":{"op":{"type":"string","enum":["init","start","done","rm","drop","append","note"]},"task":{"type":"string"},"phase":{"type":"string"},"text":{"type":"string"},"items":{"type":"array","items":{"type":"string"}},"list":{"type":"array","items":{"type":"object","properties":{"phase":{"type":"string"},"items":{"type":"array","items":{"type":"string"}}},"required":["phase","items"]}}},"required":["op"]}}},"required":["ops"]}
    """

    public var concurrency: ToolConcurrency { .exclusive }

    private let store: TodoStore

    public init(store: TodoStore, description: String? = nil) {
        self.store = store
        self.description = description ?? Self.defaultDescription
    }

    public static let defaultDescription: String = """
    Manage a phased task list to track progress within a session.

    Pass `ops`: an ordered array of operations applied in sequence.
    Allowed `op` values: `init`, `start`, `done`, `rm`, `drop`, `append`, `note`.
    `pending` is a status, not an op — leave not-yet-started tasks implicit in `init`/`append` lists.

    Operations:
    - `init` with `list: [{phase, items: string[]}]` — replace the entire list
    - `start` with `task` — mark a task in progress
    - `done` with `task` or `phase` — mark completed
    - `drop` with `task` or `phase` — mark abandoned
    - `rm` with `task` or `phase` (or neither, to clear all) — remove
    - `append` with `phase` and `items` — append tasks to a phase, lazily creating it
    - `note` with `task` and `text` — append a note to a task

    Use when: the request needs 3+ distinct steps, the user explicitly asks for one,
    the user provides a set of tasks, or new instructions arrive mid-task.
    Mark tasks done immediately after finishing them.
    """

    private struct Op: Decodable {
        let op: String
        let task: String?
        let phase: String?
        let text: String?
        let items: [String]?
        let list: [InitEntry]?
    }

    private struct InitEntry: Decodable {
        let phase: String
        let items: [String]
    }

    private struct Args: Decodable {
        let ops: [Op]
    }

    public func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8) else {
            throw ToolError.invalidArguments("Arguments are not UTF-8")
        }
        let args = try JSONDecoder.toolDecoder.decode(Args.self, from: data)

        var errors: [String] = []
        for entry in args.ops {
            await apply(entry, errors: &errors)
        }

        let phases = await store.snapshot()
        return formatSummary(phases: phases, errors: errors)
    }

    private func apply(_ entry: Op, errors: inout [String]) async {
        switch entry.op {
        case "init":
            guard let list = entry.list, !list.isEmpty else {
                errors.append("init: missing or empty `list`")
                return
            }
            let phases = list.map { TodoPhase(name: $0.phase, tasks: $0.items.map { TodoItem(content: $0) }) }
            await store.replace(with: phases)
        case "start":
            guard let task = entry.task else {
                errors.append("start: missing `task`")
                return
            }
            if !(await store.setStatus(forTask: task, status: .inProgress)) {
                errors.append("start: task not found: \(task)")
            }
        case "done":
            if let task = entry.task {
                if !(await store.setStatus(forTask: task, status: .completed)) {
                    errors.append("done: task not found: \(task)")
                }
            } else if let phase = entry.phase {
                if !(await store.setStatus(forPhase: phase, status: .completed)) {
                    errors.append("done: phase not found: \(phase)")
                }
            } else {
                errors.append("done: requires `task` or `phase`")
            }
        case "drop":
            if let task = entry.task {
                if !(await store.setStatus(forTask: task, status: .abandoned)) {
                    errors.append("drop: task not found: \(task)")
                }
            } else if let phase = entry.phase {
                if !(await store.setStatus(forPhase: phase, status: .abandoned)) {
                    errors.append("drop: phase not found: \(phase)")
                }
            } else {
                errors.append("drop: requires `task` or `phase`")
            }
        case "rm":
            if let task = entry.task {
                if !(await store.remove(task: task)) {
                    errors.append("rm: task not found: \(task)")
                }
            } else if let phase = entry.phase {
                if !(await store.remove(phase: phase)) {
                    errors.append("rm: phase not found: \(phase)")
                }
            } else {
                await store.removeAll()
            }
        case "append":
            guard let phase = entry.phase else {
                errors.append("append: missing `phase`")
                return
            }
            guard let items = entry.items, !items.isEmpty else {
                errors.append("append: missing or empty `items`")
                return
            }
            await store.append(phase: phase, items: items)
        case "note":
            guard let task = entry.task else {
                errors.append("note: missing `task`")
                return
            }
            guard let text = entry.text, !text.isEmpty else {
                errors.append("note: missing `text`")
                return
            }
            if !(await store.addNote(toTask: task, text: text)) {
                errors.append("note: task not found: \(task)")
            }
        default:
            errors.append("unknown op: \(entry.op)")
        }
    }

    private func formatSummary(phases: [TodoPhase], errors: [String]) -> String {
        var lines: [String] = []
        if phases.isEmpty {
            lines.append("(todo list is empty)")
        } else {
            for phase in phases {
                lines.append("## \(phase.name)")
                if phase.tasks.isEmpty {
                    lines.append("  (no tasks)")
                    continue
                }
                for task in phase.tasks {
                    lines.append("  \(marker(for: task.status)) \(task.content)")
                    for note in task.notes {
                        lines.append("      ↳ note: \(note)")
                    }
                }
            }
            let total = phases.reduce(0) { $0 + $1.tasks.count }
            let done = phases.reduce(0) { $0 + $1.tasks.filter { $0.status == .completed }.count }
            lines.append("")
            lines.append("Progress: \(done)/\(total) completed")
        }

        if !errors.isEmpty {
            lines.append("")
            lines.append("Errors:")
            for err in errors {
                lines.append("  - \(err)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func marker(for status: TodoStatus) -> String {
        switch status {
        case .pending: return "[ ]"
        case .inProgress: return "[~]"
        case .completed: return "[x]"
        case .abandoned: return "[-]"
        }
    }
}
