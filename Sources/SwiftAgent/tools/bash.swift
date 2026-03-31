import Foundation

public struct BashTool: AgentTool {
    public let name = "bash"
    public let description = "Execute a shell command in the working directory (SANDBOXED)"
    public let argumentSchemaJSON = """
    {"type":"object","properties":{"command":{"type":"string"},"timeoutSeconds":{"type":"number"}},"required":["command"]}
    """

    public init() {}

    public func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        struct Args: Decodable {
            let command: String
            let timeoutSeconds: Double?
        }

        guard let data = argumentsJSON.data(using: .utf8) else {
            throw ToolError.invalidArguments("Arguments are not UTF8")
        }

        let args = try JSONDecoder.toolDecoder.decode(Args.self, from: data)
        return try runCommand(args.command, cwd: context.workingDirectory, timeout: args.timeoutSeconds ?? 15)
    }

    private func runCommand(_ command: String, cwd: URL, timeout: Double) throws -> String {
        let process = Process()
        let outputPipe = Pipe()

        // 使用 sandbox-exec 动态创建一个受限环境
        // 允许: 访问系统库, /bin, /usr/bin, 以及当前工作目录
        // 拒绝: 访问个人隐私文件夹 (Documents, Desktop, etc.), 网络访问, 读写系统目录
        let workingPath = cwd.path
        let sandboxProfile = """
        (version 1)
        (deny default)
        (allow file-read* file-write* (subpath "\(workingPath)"))
        (allow file-read* (subpath "/bin"))
        (allow file-read* (subpath "/usr/bin"))
        (allow file-read* (subpath "/usr/lib"))
        (allow file-read* (subpath "/usr/share"))
        (allow file-read* (subpath "/System/Library"))
        (allow file-read* (subpath "/private/var/folders"))
        (allow process-exec (subpath "/bin"))
        (allow process-exec (subpath "/usr/bin"))
        (allow process-fork)
        (allow sysctl-read)
        (deny network-outbound)
        (deny network-inbound)
        """

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", sandboxProfile, "/bin/zsh", "-lc", command]
        
        process.currentDirectoryURL = cwd
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw ToolError.commandFailed("Unable to start sandboxed process: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            throw ToolError.commandFailed("Timed out after \(timeout)s")
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus == 0 {
            return output.isEmpty ? "Command finished successfully." : output
        } else {
            // 如果是因为沙盒拦截导致的退出，输出会包含 "Operation not permitted"
            throw ToolError.commandFailed(output.isEmpty ? "Exit code \(process.terminationStatus)" : output)
        }
    }
}
