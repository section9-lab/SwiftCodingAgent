import Foundation

public struct ToolExecutionContext: Sendable {
    public let workingDirectory: URL
    public let executionPolicy: ToolExecutionPolicy

    public var allowedRoots: [URL] {
        executionPolicy.fileAccess.allowedRoots
    }

    public var bashExecutionPolicy: BashExecutionPolicy {
        executionPolicy.bash
    }

    public init(
        workingDirectory: URL,
        allowedRoots: [URL]? = nil,
        bashExecutionPolicy: BashExecutionPolicy = .sandboxed(.init())
    ) {
        self.workingDirectory = workingDirectory
        self.executionPolicy = ToolExecutionPolicy(
            workingDirectory: workingDirectory,
            allowedRoots: allowedRoots ?? [],
            bash: bashExecutionPolicy
        )
    }

    public init(workingDirectory: URL, executionPolicy: ToolExecutionPolicy) {
        self.workingDirectory = workingDirectory
        self.executionPolicy = executionPolicy
    }
}

public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var argumentSchemaJSON: String { get }

    func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String
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

    public func allSpecs() -> [ModelToolSpec] {
        tools.values
            .map { ModelToolSpec(name: $0.name, description: $0.description, argumentSchemaJSON: $0.argumentSchemaJSON) }
            .sorted { $0.name < $1.name }
    }

    public func run(call: ToolCall, context: ToolExecutionContext) async throws -> String {
        guard let tool = tools[call.name] else {
            throw ToolError.toolNotFound(call.name)
        }
        return try await tool.run(argumentsJSON: call.argumentsJSON, context: context)
    }
}

extension JSONDecoder {
    static var toolDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }
}
