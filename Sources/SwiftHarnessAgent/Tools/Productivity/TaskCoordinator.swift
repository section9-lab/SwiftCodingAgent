import Foundation

/// Definition of a sub-agent that can be spawned by `TaskTool`. Each
/// definition is a stateless template — every spawn gets a fresh `AgentLoop`
/// seeded with the system prompt, tools, and skills declared here.
public struct SubagentDefinition: Sendable {
    public let id: String
    public let displayName: String
    public let description: String
    public let systemPrompt: String
    public let tools: [any AgentTool]
    public let skills: [any AgentSkill]
    /// Step ceiling for this subagent. Mirrors `AgentLoopConfig.maxSteps`.
    public let maxSteps: Int?

    public init(
        id: String,
        displayName: String,
        description: String,
        systemPrompt: String,
        tools: [any AgentTool] = [],
        skills: [any AgentSkill] = [],
        maxSteps: Int? = 16
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.skills = skills
        self.maxSteps = maxSteps
    }
}

/// One unit of work dispatched to a subagent.
public struct SubagentTaskRequest: Sendable {
    public let id: String
    public let agentId: String
    public let description: String
    public let assignment: String
    public let context: String?

    public init(id: String, agentId: String, description: String, assignment: String, context: String?) {
        self.id = id
        self.agentId = agentId
        self.description = description
        self.assignment = assignment
        self.context = context
    }
}

/// Result of one subagent task. Mirrors the prose-only "yield" shape used by
/// pi-coding-agent's subagent system: the subagent's final assistant text is
/// returned verbatim so the parent agent can decide what to do with it.
public struct SubagentTaskResult: Sendable {
    public let id: String
    public let agentId: String
    public let success: Bool
    public let output: String
    public let steps: Int
    public let error: String?

    public init(id: String, agentId: String, success: Bool, output: String, steps: Int, error: String? = nil) {
        self.id = id
        self.agentId = agentId
        self.success = success
        self.output = output
        self.steps = steps
        self.error = error
    }
}

/// Spawns subagents on demand. Owns the model factory and execution policy
/// used to build each child loop, so callers (including `TaskTool`) only need
/// to supply the request payload.
public actor TaskCoordinator {
    public typealias ModelFactory = @Sendable (SubagentDefinition) -> any AgentModel

    private let definitions: [String: SubagentDefinition]
    private let modelFactory: ModelFactory
    private let workingDirectory: URL
    private let executionPolicy: ToolExecutionPolicy
    private let maxConcurrency: Int

    public init(
        definitions: [SubagentDefinition],
        modelFactory: @escaping ModelFactory,
        workingDirectory: URL,
        executionPolicy: ToolExecutionPolicy,
        maxConcurrency: Int = 4
    ) {
        var byID: [String: SubagentDefinition] = [:]
        for def in definitions {
            byID[def.id] = def
        }
        self.definitions = byID
        self.modelFactory = modelFactory
        self.workingDirectory = workingDirectory
        self.executionPolicy = executionPolicy
        self.maxConcurrency = max(1, maxConcurrency)
    }

    public func availableAgents() -> [SubagentDefinition] {
        definitions.values.sorted { $0.id < $1.id }
    }

    /// Run a batch of subagent tasks with bounded parallelism. Tasks that
    /// reference an unknown agent fail individually with a synthetic
    /// `SubagentTaskResult` instead of aborting the whole batch.
    public func run(tasks: [SubagentTaskRequest]) async -> [SubagentTaskResult] {
        guard !tasks.isEmpty else { return [] }

        return await withTaskGroup(of: (Int, SubagentTaskResult).self) { group in
            var inFlight = 0
            var nextIndex = 0
            var collected: [(Int, SubagentTaskResult)] = []

            // Seed up to maxConcurrency.
            while nextIndex < tasks.count && inFlight < maxConcurrency {
                let index = nextIndex
                let task = tasks[index]
                group.addTask { [self] in
                    let result = await self.runOne(task)
                    return (index, result)
                }
                nextIndex += 1
                inFlight += 1
            }

            while let next = await group.next() {
                collected.append(next)
                inFlight -= 1
                if nextIndex < tasks.count {
                    let index = nextIndex
                    let task = tasks[index]
                    group.addTask { [self] in
                        let result = await self.runOne(task)
                        return (index, result)
                    }
                    nextIndex += 1
                    inFlight += 1
                }
            }

            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    private func runOne(_ task: SubagentTaskRequest) async -> SubagentTaskResult {
        guard let definition = definitions[task.agentId] else {
            return SubagentTaskResult(
                id: task.id,
                agentId: task.agentId,
                success: false,
                output: "",
                steps: 0,
                error: "unknown agent: \(task.agentId)"
            )
        }

        let model = modelFactory(definition)
        var skills: [any AgentSkill] = definition.skills
        if !definition.systemPrompt.isEmpty {
            skills.insert(BasicSkill(name: "subagent.\(definition.id)", systemPrompt: definition.systemPrompt), at: 0)
        }

        let loop = AgentLoop(
            model: model,
            skills: skills,
            tools: definition.tools,
            config: AgentLoopConfig(
                maxSteps: definition.maxSteps,
                workingDirectory: workingDirectory,
                executionPolicy: executionPolicy
            )
        )

        var prompt = ""
        if let ctx = task.context, !ctx.isEmpty {
            prompt += "## Shared Context\n\(ctx)\n\n"
        }
        prompt += "## Assignment\n\(task.assignment)\n"
        if !task.description.isEmpty {
            prompt = "Task: \(task.description)\n\n" + prompt
        }

        do {
            let result = try await loop.run(userInput: prompt)
            return SubagentTaskResult(
                id: task.id,
                agentId: task.agentId,
                success: true,
                output: result.finalText,
                steps: result.steps
            )
        } catch {
            return SubagentTaskResult(
                id: task.id,
                agentId: task.agentId,
                success: false,
                output: "",
                steps: 0,
                error: error.localizedDescription
            )
        }
    }
}
