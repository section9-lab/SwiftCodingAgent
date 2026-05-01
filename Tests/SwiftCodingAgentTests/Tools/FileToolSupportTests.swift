import Testing
@testable import SwiftCodingAgent
import Foundation

struct FileToolSupportTests {
    @Test
    func rejectsPathOutsideAllowedRoots() throws {
        let root = URL(fileURLWithPath: "/tmp/scag-test-allowed")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            _ = try FileToolSupport.resolvePath(
                "/etc/passwd",
                in: root,
                allowedRoots: [root]
            )
            Issue.record("Expected escape to be rejected")
        } catch {
            // expected
        }
    }

    @Test
    func rejectsSymlinkEscape() throws {
        let fm = FileManager.default
        let unique = UUID().uuidString
        let root = URL(fileURLWithPath: "/tmp/scag-symlink-\(unique)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Create root/link -> /tmp (outside the root). Then ask to read
        // root/link/some-file. Per-segment resolution must reject this even
        // though the literal path string starts with the root prefix.
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/tmp"))

        do {
            _ = try FileToolSupport.resolvePath(
                "link/anything",
                in: root,
                allowedRoots: [root]
            )
            Issue.record("Expected symlink escape to be rejected")
        } catch {
            // expected
        }
    }

    @Test
    func allowsResolutionWithinRoot() throws {
        let fm = FileManager.default
        let unique = UUID().uuidString
        let root = URL(fileURLWithPath: "/tmp/scag-allowed-\(unique)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let nested = root.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("a.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)

        let resolved = try FileToolSupport.resolvePath(
            "nested/a.txt",
            in: root,
            allowedRoots: [root]
        )

        #expect(resolved.path.hasSuffix("nested/a.txt"))
    }
}
