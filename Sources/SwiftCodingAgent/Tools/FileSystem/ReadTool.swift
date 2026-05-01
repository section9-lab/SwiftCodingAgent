import Foundation

public struct ReadTool: AgentTool {
    public let name = "read"
    public let description = "Read a UTF-8 text file. Large files are truncated."
    public let argumentSchemaJSON = """
    {"type":"object","properties":{"path":{"type":"string"},"maxBytes":{"type":"integer"}},"required":["path"]}
    """

    /// Default cap to keep a single tool result from blowing past the model's
    /// context window. The model can override per-call via `maxBytes`.
    public static let defaultMaxBytes: Int = 256 * 1024
    public let maxBytes: Int

    public init(maxBytes: Int = ReadTool.defaultMaxBytes) {
        self.maxBytes = maxBytes
    }

    public func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        struct Args: Decodable {
            let path: String
            let maxBytes: Int?
        }
        guard let data = argumentsJSON.data(using: .utf8) else {
            throw ToolError.invalidArguments("Arguments are not UTF-8")
        }
        let args = try JSONDecoder.toolDecoder.decode(Args.self, from: data)
        let fileURL = try FileToolSupport.resolvePath(args.path, in: context.workingDirectory, allowedRoots: context.allowedRoots)

        let cap = max(1, args.maxBytes ?? maxBytes)

        let raw: Data
        do {
            raw = try Data(contentsOf: fileURL)
        } catch {
            throw ToolError.fileOperationFailed("Cannot read file: \(args.path)")
        }

        let truncated = raw.count > cap
        let slice = truncated ? raw.prefix(cap) : raw

        guard let text = String(data: slice, encoding: .utf8) else {
            throw ToolError.fileOperationFailed("File is not valid UTF-8: \(args.path)")
        }

        if truncated {
            return text + "\n\n...(truncated \(raw.count - cap) bytes; pass a larger maxBytes to read more)"
        }
        return text
    }
}
