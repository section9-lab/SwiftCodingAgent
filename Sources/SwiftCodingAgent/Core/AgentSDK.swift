import Foundation

public actor AgentSDK {
    private let loop: AgentLoop

    public init(
        model: any AgentModel,
        summarizerModel: (any AgentModel)? = nil,
        skills: [any AgentSkill] = [],
        tools: [any AgentTool] = [],
        workingDirectory: URL,
        allowedRoots: [URL] = [],
        executionPolicy: ToolExecutionPolicy? = nil,
        toolExecutionContexts: [String: ToolExecutionContext] = [:],
        maxSteps: Int? = 8,
        compaction: CompactionConfig = .init(),
        skillsDirectories: [URL] = [],
        approvalHandler: ToolApprovalHandler? = nil
    ) {
        let builtinTools: [any AgentTool] = [
            ReadTool(),
            WriteTool(),
            EditTool(),
            BashTool()
        ]

        var allSkills: [any AgentSkill] = Array(skills)
        for dir in skillsDirectories {
            allSkills.append(contentsOf: SkillLoader.loadSkills(from: dir))
        }

        self.loop = AgentLoop(
            model: model,
            summarizerModel: summarizerModel,
            skills: allSkills,
            tools: builtinTools + tools,
            config: AgentLoopConfig(
                maxSteps: maxSteps,
                workingDirectory: workingDirectory,
                allowedRoots: allowedRoots,
                executionPolicy: executionPolicy,
                toolExecutionContexts: toolExecutionContexts,
                compaction: compaction,
                approvalHandler: approvalHandler
            )
        )
    }

    public func run(prompt: String) async throws -> AgentRunResult {
        try await loop.run(userInput: prompt)
    }

    /// Streamed variant of `run`. AI text is yielded incrementally as
    /// `.textDelta` events; tool calls/results are batched. See `AgentEvent`.
    public nonisolated func runStream(prompt: String) -> AsyncThrowingStream<AgentEvent, Error> {
        loop.runStream(userInput: prompt)
    }

    public func history() async -> [AgentMessage] {
        await loop.history()
    }

    public func compactionSummary() async -> String? {
        await loop.currentCompactionSummary()
    }

    public func compact(customInstructions: String? = nil) async throws -> String? {
        try await loop.compact(customInstructions: customInstructions)
    }

    public func contextUsage() async -> ContextUsage {
        await loop.contextUsage()
    }
}
