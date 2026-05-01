import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum FileToolSupport {
    /// Resolve `rawPath` (absolute or relative to `workingDirectory`) and verify
    /// that the resulting path lies within one of `allowedRoots`.
    ///
    /// Symlinks are resolved with POSIX `realpath(3)` so a malicious link
    /// inside the root cannot redirect a path component outside it. Paths that
    /// don't yet exist (e.g. files about to be written) have their deepest
    /// existing ancestor resolved, with the remaining components appended
    /// literally.
    static func resolvePath(_ rawPath: String, in workingDirectory: URL, allowedRoots: [URL]) throws -> URL {
        let candidate: URL
        if rawPath.hasPrefix("/") {
            candidate = URL(fileURLWithPath: rawPath)
        } else {
            candidate = workingDirectory.appendingPathComponent(rawPath)
        }

        let standardized = candidate.standardizedFileURL
        let canonical = canonicalize(standardized.path)

        let roots = allowedRoots.isEmpty ? [workingDirectory] : allowedRoots
        let isAllowed = roots.contains { root in
            let canonicalRoot = canonicalize(root.standardizedFileURL.path)
            return isPath(canonical, withinRoot: canonicalRoot)
        }

        guard isAllowed else {
            throw ToolError.fileOperationFailed("Path is outside authorized roots: \(rawPath)")
        }

        return standardized
    }

    /// Resolve all symlinks in `path` to their canonical form. If the leaf
    /// doesn't exist, walk back to the deepest existing ancestor, canonicalize
    /// that, and append the remaining components literally.
    static func canonicalize(_ path: String) -> String {
        if let real = realpathOrNil(path) {
            return real
        }

        // Path (or some suffix) doesn't exist. Find the deepest existing prefix.
        let fm = FileManager.default
        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var trailing: [String] = []

        while !components.isEmpty {
            let current = "/" + components.joined(separator: "/")
            if fm.fileExists(atPath: current), let real = realpathOrNil(current) {
                let combined = real + (trailing.isEmpty ? "" : "/" + trailing.reversed().joined(separator: "/"))
                return combined
            }
            trailing.append(components.removeLast())
        }

        // Nothing existed — return the input as-is (after normalisation).
        return (path as NSString).standardizingPath
    }

    private static func realpathOrNil(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isPath(_ path: String, withinRoot root: String) -> Bool {
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }
}
