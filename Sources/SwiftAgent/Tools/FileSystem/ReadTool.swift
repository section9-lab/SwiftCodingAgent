import Foundation

public struct ReadTool: AgentTool {
    public let name = "read"
    public let description = "Read a UTF-8 text file"
    public let argumentSchemaJSON = """
    {"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
    """

    public init() {}

    public func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        struct Args: Decodable { let path: String }
        guard let data = argumentsJSON.data(using: .utf8) else {
            throw ToolError.invalidArguments("Arguments are not UTF-8")
        }
        let args = try JSONDecoder.toolDecoder.decode(Args.self, from: data)
        let fileURL = try FileToolSupport.resolvePath(args.path, in: context.workingDirectory, allowedRoots: context.allowedRoots)

        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw ToolError.fileOperationFailed("Cannot read file: \(args.path)")
        }
    }
}
