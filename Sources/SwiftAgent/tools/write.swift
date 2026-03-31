import Foundation

public struct WriteTool: AgentTool {
    public let name = "write"
    public let description = "Write UTF-8 text to a file, creating parent directories if needed"
    public let argumentSchemaJSON = """
    {"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"append":{"type":"boolean"}},"required":["path","content"]}
    """

    public init() {}

    public func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        struct Args: Decodable {
            let path: String
            let content: String
            let append: Bool?
        }

        guard let data = argumentsJSON.data(using: .utf8) else {
            throw ToolError.invalidArguments("Arguments are not UTF-8")
        }
        let args = try JSONDecoder.toolDecoder.decode(Args.self, from: data)
        let fileURL = try FileToolSupport.resolvePath(args.path, in: context.workingDirectory, allowedRoots: context.allowedRoots)

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )

            if args.append == true, let handle = try? FileHandle(forWritingTo: fileURL) {
                try handle.seekToEnd()
                if let data = args.content.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } else {
                try args.content.write(to: fileURL, atomically: true, encoding: .utf8)
            }
            return "Wrote \(args.content.count) chars to \(args.path)"
        } catch {
            throw ToolError.fileOperationFailed("Cannot write file: \(args.path)")
        }
    }
}
