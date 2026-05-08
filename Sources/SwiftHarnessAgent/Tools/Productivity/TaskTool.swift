import Foundation

/// `task` tool. Spawns subagents in parallel through a `TaskCoordinator`.
/// Each task targets a single subagent definition (`agent`) and carries a
/// self-contained assignment; `context` is shared across the whole batch.
public struct TaskTool: AgentTool {
    public let name = "task"
    public let description: String
    public let argumentSchemaJSON = """
    {"type":"object","properties":{"agent":{"type":"string"},"context":{"type":"string"},"tasks":{"type":"array","minItems":1,"items":{"type":"object","properties":{"id":{"type":"string","maxLength":48},"description":{"type":"string"},"assignment":{"type":"string"}},"required":["id","description","assignment"]}}},"required":["agent","tasks"]}
    """

    private let coordinator: TaskCoordinator

    public init(coordinator: TaskCoordinator, description: String? = nil) {
        self.coordinator = coordinator
        self.description = description ?? Self.defaultDescription
    }

    public static let defaultDescription: String = """
    Launch one or more subagents in parallel to fan out work.

    Subagents have no conversation history. Every fact, file path, and decision they need MUST be explicit in `context` (shared) or `assignment` (per task).

    Parameters:
    - `agent`: subagent id used for every task in this batch
    - `context`: shared background prepended to every assignment (goal, constraints, contracts)
    - `tasks: [{id, description, assignment}]`
      - `id`: CamelCase, ≤48 chars, unique within the batch
      - `description`: short label for UI; subagent does not see it
      - `assignment`: complete self-contained instructions

    Rules:
    - Default to parallel. Sequence A→B only if B needs A's output.
    - Each task should touch ≤3-5 explicit files; fan out instead of widening one task.
    - Do not assign project-wide build/test/lint to a subagent — caller verifies after the batch.
    """

    /// Description that lists the available agent definitions. Useful when the
    /// hosting app wants the model to see the menu of agents at registration
    /// time. Pass the result to the `description:` parameter when building the
    /// tool.
    public static func description(includingAgents agents: [SubagentDefinition]) -> String {
        guard !agents.isEmpty else { return defaultDescription }
        var lines = [defaultDescription, "", "Available agents:"]
        for agent in agents {
            lines.append("- `\(agent.id)` — \(agent.description)")
        }
        return lines.joined(separator: "\n")
    }

    private struct TaskPayload: Decodable {
        let id: String
        let description: String
        let assignment: String
    }

    private struct Args: Decodable {
        let agent: String
        let context: String?
        let tasks: [TaskPayload]
    }

    public func run(argumentsJSON: String, context ctx: ToolExecutionContext) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8) else {
            throw ToolError.invalidArguments("Arguments are not UTF-8")
        }
        let args = try JSONDecoder.toolDecoder.decode(Args.self, from: data)

        guard !args.tasks.isEmpty else {
            throw ToolError.invalidArguments("`tasks` must contain at least one item")
        }

        var seenIDs: Set<String> = []
        for task in args.tasks {
            if !seenIDs.insert(task.id).inserted {
                throw ToolError.invalidArguments("duplicate task id: \(task.id)")
            }
            if task.assignment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ToolError.invalidArguments("task \(task.id): empty assignment")
            }
        }

        let requests = args.tasks.map {
            SubagentTaskRequest(
                id: $0.id,
                agentId: args.agent,
                description: $0.description,
                assignment: $0.assignment,
                context: args.context
            )
        }

        let results = await coordinator.run(tasks: requests)
        return formatResults(results)
    }

    private func formatResults(_ results: [SubagentTaskResult]) -> String {
        var lines: [String] = []
        for result in results {
            let header = "## Task \(result.id) (\(result.agentId)) — \(result.success ? "success" : "failed")"
            lines.append(header)
            lines.append("steps: \(result.steps)")
            if let error = result.error, !error.isEmpty {
                lines.append("error: \(error)")
            }
            if !result.output.isEmpty {
                lines.append("")
                lines.append(result.output)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
