import Foundation

enum FileToolSupport {
    static func resolvePath(_ rawPath: String, in workingDirectory: URL, allowedRoots: [URL]) throws -> URL {
        let candidate: URL
        if rawPath.hasPrefix("/") {
            candidate = URL(fileURLWithPath: rawPath)
        } else {
            candidate = workingDirectory.appendingPathComponent(rawPath)
        }

        let standardized = candidate.standardizedFileURL
        let resolvedCandidate = resolvedPathForBoundaryCheck(standardized)

        let roots = allowedRoots.isEmpty ? [workingDirectory] : allowedRoots
        let isAllowed = roots.contains { root in
            let resolvedRoot = resolvedPathForBoundaryCheck(root.standardizedFileURL)
            let rootPath = resolvedRoot.path
            let candidatePath = resolvedCandidate.path
            return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
        }

        guard isAllowed else {
            throw ToolError.fileOperationFailed("Path is outside authorized roots: \(rawPath)")
        }

        return standardized
    }

    private static func resolvedPathForBoundaryCheck(_ url: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().standardizedFileURL
        }

        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return parent.appendingPathComponent(url.lastPathComponent)
    }
}
