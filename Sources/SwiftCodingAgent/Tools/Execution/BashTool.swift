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
        try await requestApprovalIfNeeded(for: args.command, context: context)

        #if os(macOS)
        return try runCommand(
            args.command,
            cwd: context.workingDirectory,
            timeout: args.timeoutSeconds ?? 15,
            allowedRoots: context.allowedRoots,
            policy: context.bashExecutionPolicy
        )
        #else
        // Process / sandbox-exec are macOS-only. iOS sandboxes the host app
        // itself, and Linux would need a different sandbox mechanism (seccomp,
        // bubblewrap, etc.). Fail loudly rather than silently no-op.
        throw ToolError.commandFailed("BashTool is only supported on macOS in this build")
        #endif
    }

    #if os(macOS)
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
    #endif

    private func requestApprovalIfNeeded(for command: String, context: ToolExecutionContext) async throws {
        guard let risk = BashRiskClassifier.classify(command) else { return }
        guard let approvalHandler = context.approvalHandler else {
            throw ToolError.commandFailed("User approval required before running this command: \(risk.reason)")
        }

        let decision = await approvalHandler(
            ToolApprovalRequest(
                toolName: name,
                summary: command,
                reason: risk.reason
            )
        )

        switch decision {
        case .approved:
            return
        case .rejected:
            throw ToolError.commandFailed("User rejected command: \(command)")
        }
    }
}

private enum BashRiskClassifier {
    struct Risk {
        let reason: String
    }

    static func classify(_ command: String) -> Risk? {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let lower = normalized.lowercased()

        if containsRemoteScriptExecution(lower) {
            return Risk(reason: "This command downloads and executes remote code.")
        }

        if containsSensitiveRead(lower) {
            return Risk(reason: "This command may read credentials, tokens, or private keys.")
        }

        if containsDestructiveFileOperation(lower) {
            return Risk(reason: "This command may delete, overwrite, or recursively change files.")
        }

        if containsDangerousGitOperation(lower) {
            return Risk(reason: "This command can discard history, remove files, or rewrite remote branches.")
        }

        if lower.contains("sudo") || writesSystemPath(lower) {
            return Risk(reason: "This command may modify system-level files or privileges.")
        }

        if sendsLocalFileOverNetwork(lower) {
            return Risk(reason: "This command may upload local files or project data over the network.")
        }

        return nil
    }

    private static func containsRemoteScriptExecution(_ command: String) -> Bool {
        let hasDownloader = command.contains("curl ") || command.contains("wget ")
        let pipesToShell = command.contains("| sh") || command.contains("| bash") || command.contains("| zsh")
        return hasDownloader && pipesToShell
    }

    private static func containsSensitiveRead(_ command: String) -> Bool {
        let sensitivePatterns = [
            ".env",
            "id_rsa",
            "id_ed25519",
            ".ssh/",
            "token",
            "secret",
            "keychain",
            "login.keychain",
            "cookies.sqlite",
            "history/login data"
        ]

        return sensitivePatterns.contains { command.contains($0) }
    }

    private static func containsDestructiveFileOperation(_ command: String) -> Bool {
        let destructivePatterns = [
            "rm ",
            "rm\t",
            "rm -",
            "rm -rf",
            "rm -fr",
            " -delete",
            "trash ",
            "shred ",
            "chmod -r",
            "chown -r",
            "cp -f"
        ]

        if command.contains("find ") && command.contains(" -delete") {
            return true
        }

        return destructivePatterns.contains { command.contains($0) }
    }

    private static func containsDangerousGitOperation(_ command: String) -> Bool {
        let gitPatterns = [
            "git reset --hard",
            "git clean",
            "git push --force",
            "git push -f",
            "git branch -d",
            "git branch -D",
            "git tag -d",
            "git checkout --",
            "git restore "
        ]

        return gitPatterns.contains { command.contains($0.lowercased()) }
    }

    private static func writesSystemPath(_ command: String) -> Bool {
        let systemPaths = [
            " /system/",
            " /usr/",
            " /bin/",
            " /sbin/",
            " /etc/",
            " /library/",
            ">/system/",
            ">/usr/",
            ">/bin/",
            ">/sbin/",
            ">/etc/",
            ">/library/"
        ]

        return systemPaths.contains { command.contains($0) }
    }

    private static func sendsLocalFileOverNetwork(_ command: String) -> Bool {
        guard command.contains("curl ") || command.contains("wget ") || command.contains("scp ") || command.contains("rsync ") else {
            return false
        }

        return command.contains("-f ") ||
            command.contains("--form") ||
            command.contains("--data-binary") ||
            command.contains("@/") ||
            command.contains("@.")
    }
}
