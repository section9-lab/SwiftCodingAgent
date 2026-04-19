import Foundation

public struct FileAccessPolicy: Sendable {
    public let allowedRoots: [URL]

    public init(allowedRoots: [URL] = []) {
        self.allowedRoots = Self.normalizeRoots(allowedRoots)
    }

    public init(workingDirectory: URL, allowedRoots: [URL] = []) {
        self.init(allowedRoots: [workingDirectory] + allowedRoots)
    }

    private static func normalizeRoots(_ roots: [URL]) -> [URL] {
        var normalized: [URL] = []

        for root in roots {
            let standardized = root.standardizedFileURL
            let path = standardized.path

            if !normalized.contains(where: { $0.path == path }) {
                normalized.append(standardized)
            }
        }

        return normalized
    }
}

public struct BashSandboxPolicy: Sendable {
    public let allowNetwork: Bool

    public init(allowNetwork: Bool = false) {
        self.allowNetwork = allowNetwork
    }
}

public enum BashExecutionPolicy: Sendable {
    case disabled
    case sandboxed(BashSandboxPolicy)
    case unrestricted
}

public struct ToolExecutionPolicy: Sendable {
    public let fileAccess: FileAccessPolicy
    public let bash: BashExecutionPolicy

    public init(
        allowedRoots: [URL] = [],
        bash: BashExecutionPolicy = .sandboxed(.init())
    ) {
        self.init(
            fileAccess: FileAccessPolicy(allowedRoots: allowedRoots),
            bash: bash
        )
    }

    public init(
        workingDirectory: URL,
        allowedRoots: [URL] = [],
        bash: BashExecutionPolicy = .sandboxed(.init())
    ) {
        self.init(
            fileAccess: FileAccessPolicy(workingDirectory: workingDirectory, allowedRoots: allowedRoots),
            bash: bash
        )
    }

    public init(
        fileAccess: FileAccessPolicy,
        bash: BashExecutionPolicy = .sandboxed(.init())
    ) {
        self.fileAccess = fileAccess
        self.bash = bash
    }
}
