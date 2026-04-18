import Foundation

public struct BashTool: AgentTool {
    public let name = "bash"
    public let description = "Execute a shell command in the working directory subject to the configured bash execution policy"
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
        return try runCommand(
            args.command,
            cwd: context.workingDirectory,
            timeout: args.timeoutSeconds ?? 15,
            allowedRoots: context.allowedRoots,
            policy: context.bashExecutionPolicy
        )
    }

    private func runCommand(
        _ command: String,
        cwd: URL,
        timeout: Double,
        allowedRoots: [URL],
        policy: BashExecutionPolicy
    ) throws -> String {
        switch policy {
        case .disabled:
            throw ToolError.commandFailed("Bash tool is disabled by the current execution policy")
        case .unrestricted:
            return try runProcess(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-f", "-c", command],
                cwd: cwd,
                timeout: timeout
            )
        case .sandboxed(let sandboxPolicy):
            let sandboxProfile = makeSandboxProfile(
                writableRoots: allowedRoots,
                allowNetwork: sandboxPolicy.allowNetwork
            )

            return try runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", sandboxProfile, "/bin/zsh", "-f", "-c", command],
                cwd: cwd,
                timeout: timeout
            )
        }
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        cwd: URL,
        timeout: Double
    ) throws -> String {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
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
            throw ToolError.commandFailed(output.isEmpty ? "Exit code \(process.terminationStatus)" : output)
        }
    }

    private func makeSandboxProfile(writableRoots: [URL], allowNetwork: Bool) -> String {
        let normalizedRoots = writableRoots.map(\.standardizedFileURL)
        let rootRules = normalizedRoots
            .map { "(allow file-read* file-write* (subpath \"\(escapeSandboxPath($0.path))\"))" }
            .joined(separator: "\n")

        let networkRules: String
        if allowNetwork {
            networkRules = """
            (allow network-outbound)
            (allow network-inbound)
            """
        } else {
            networkRules = """
            (deny network-outbound)
            (deny network-inbound)
            """
        }

        return """
        (version 1)
        (deny default)
        \(rootRules)
        (allow file-read* (subpath "/bin"))
        (allow file-read* (subpath "/usr/bin"))
        (allow file-read* (subpath "/usr/lib"))
        (allow file-read* (subpath "/usr/share"))
        (allow file-read* (subpath "/System/Library"))
        (allow file-read* file-write* (subpath "/private/var/folders"))
        (allow file-read* file-write* (subpath "/tmp"))
        (allow file-read* file-write* (subpath "/private/tmp"))
        (allow process-exec (subpath "/bin"))
        (allow process-exec (subpath "/usr/bin"))
        (allow process-fork)
        (allow sysctl-read)
        \(networkRules)
        """
    }

    private func escapeSandboxPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
