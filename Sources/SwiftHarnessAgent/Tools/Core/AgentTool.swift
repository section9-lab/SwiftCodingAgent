import Foundation

/// Defines how a tool can be executed relative to other tools in the same turn.
public enum ToolConcurrency: String, Sendable {
    /// Can run in parallel with other shared tools.
    case shared
    /// Must run exclusively; other tools wait for it to complete.
    case exclusive
}

public struct ToolExecutionContext: Sendable {
    public let workingDirectory: URL
    public let executionPolicy: ToolExecutionPolicy
    public let approvalHandler: ToolApprovalHandler?

    public var allowedRoots: [URL] {
        executionPolicy.fileAccess.allowedRoots
    }

    public var bashExecutionPolicy: BashExecutionPolicy {
        executionPolicy.bash
    }

    public init(
        workingDirectory: URL,
        allowedRoots: [URL]? = nil,
        bashExecutionPolicy: BashExecutionPolicy = .sandboxed(.init()),
        approvalHandler: ToolApprovalHandler? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.approvalHandler = approvalHandler
        let explicitRoots = allowedRoots ?? []
        let effectiveRoots = explicitRoots.isEmpty ? [workingDirectory] : explicitRoots
        self.executionPolicy = ToolExecutionPolicy(
            allowedRoots: effectiveRoots,
            bash: bashExecutionPolicy
        )
    }

    public init(
        workingDirectory: URL,
        executionPolicy: ToolExecutionPolicy,
        approvalHandler: ToolApprovalHandler? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.executionPolicy = executionPolicy
        self.approvalHandler = approvalHandler
    }

    public func withApprovalHandler(_ approvalHandler: ToolApprovalHandler?) -> ToolExecutionContext {
        ToolExecutionContext(
            workingDirectory: workingDirectory,
            executionPolicy: executionPolicy,
            approvalHandler: approvalHandler ?? self.approvalHandler
        )
    }
}

public enum ToolApprovalDecision: Sendable {
    case approved
    case rejected
}

public struct ToolApprovalRequest: Identifiable, Sendable {
    public let id: UUID
    public let toolName: String
    public let summary: String
    public let reason: String

    public init(
        id: UUID = UUID(),
        toolName: String,
        summary: String,
        reason: String
    ) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.reason = reason
    }
}

public typealias ToolApprovalHandler = @Sendable (ToolApprovalRequest) async -> ToolApprovalDecision

public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var argumentSchemaJSON: String { get }
    /// Concurrency mode. Defaults to `.shared` (safe for parallel execution).
    var concurrency: ToolConcurrency { get }

    func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String
}

// Default implementation: most tools are read-only and safe to parallelize.
extension AgentTool {
    public var concurrency: ToolConcurrency { .shared }
}

public enum ToolError: LocalizedError {
    case toolNotFound(String)
    case invalidArguments(String)
    case commandFailed(String)
    case fileOperationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .invalidArguments(let message):
            return "Invalid arguments: \(message)"
        case .commandFailed(let message):
            return "Command failed: \(message)"
        case .fileOperationFailed(let message):
            return "File operation failed: \(message)"
        }
    }
}

public actor ToolRegistry {
    private var tools: [String: any AgentTool] = [:]

    public init(tools: [any AgentTool] = []) {
        for tool in tools {
            self.tools[tool.name] = tool
        }
    }

    public func register(_ tool: any AgentTool) {
        tools[tool.name] = tool
    }

    public func register(_ tools: [any AgentTool]) {
        for tool in tools {
            self.tools[tool.name] = tool
        }
    }

    public func allSpecs() -> [LLMToolSpec] {
        tools.values
            .map { LLMToolSpec(name: $0.name, description: $0.description, argumentSchemaJSON: $0.argumentSchemaJSON) }
            .sorted { $0.name < $1.name }
    }

    /// Returns the declared concurrency for a tool, or `.shared` (the safe
    /// default) when the tool isn't registered. The fallback never matters in
    /// practice — callers always check registration before scheduling — but
    /// keeps the contract total.
    public func concurrency(for toolName: String) -> ToolConcurrency {
        tools[toolName]?.concurrency ?? .shared
    }

    public func run(use: LLMToolUse, context: ToolExecutionContext) async throws -> String {
        guard let tool = tools[use.name] else {
            throw ToolError.toolNotFound(use.name)
        }
        return try await tool.run(argumentsJSON: use.argumentsJSON, context: context)
    }
}

extension JSONDecoder {
    static var toolDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }
}
