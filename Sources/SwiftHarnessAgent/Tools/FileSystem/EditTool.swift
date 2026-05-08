import Foundation

public struct EditTool: AgentTool {
    public let name = "edit"
    public let description = "Find exact oldText in file and replace with newText"
    public let argumentSchemaJSON = """
    {"type":"object","properties":{"path":{"type":"string"},"oldText":{"type":"string"},"newText":{"type":"string"}},"required":["path","oldText","newText"]}
    """

    public init() {}

    public var concurrency: ToolConcurrency { .exclusive }

    public func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        struct Args: Decodable {
            let path: String
            let oldText: String
            let newText: String
        }

        guard let data = argumentsJSON.data(using: .utf8) else {
            throw ToolError.invalidArguments("Arguments are not UTF-8")
        }

        let args = try JSONDecoder.toolDecoder.decode(Args.self, from: data)
        let fileURL = try FileToolSupport.resolvePath(args.path, in: context.workingDirectory, allowedRoots: context.allowedRoots)

        let original: String
        do {
            original = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw ToolError.fileOperationFailed("Cannot read file: \(args.path)")
        }

        guard original.contains(args.oldText) else {
            throw ToolError.fileOperationFailed("oldText not found in file: \(args.path)")
        }

        let updated = original.replacingOccurrences(of: args.oldText, with: args.newText)
        do {
            try updated.write(to: fileURL, atomically: true, encoding: .utf8)
            return "Edited file: \(args.path)"
        } catch {
            throw ToolError.fileOperationFailed("Cannot write edited file: \(args.path)")
        }
    }
}
