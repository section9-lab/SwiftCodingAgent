import Foundation

/// Loads skills from a directory following the cross-platform SKILL.md standard.
/// Compatible with Claude Code, Codex CLI, and pi-coding-agent skill format.
///
/// Expected structure:
/// ```
/// .skills/
///   skill-name/
///     SKILL.md       ← required (YAML frontmatter + markdown body)
///     scripts/       ← optional
///     docs/          ← optional
/// ```
public struct SkillLoader: Sendable {

    /// Scan a directory for subdirectories containing SKILL.md and return them as BasicSkills.
    /// Only injects metadata (name, description, file path) into the system prompt.
    /// The agent should use the `read` tool to load full skill instructions when needed.
    public static func loadSkills(from directory: URL) -> [BasicSkill] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }

        guard let children = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var skills: [BasicSkill] = []

        for child in children {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let skillFile = child.appendingPathComponent("SKILL.md")
            guard let content = try? String(contentsOf: skillFile, encoding: .utf8),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }

            let parsed = parseFrontmatter(content)
            let name = parsed?.name.isEmpty == false ? parsed!.name : child.lastPathComponent
            let description = parsed?.description ?? ""
            let filePath = skillFile.path

            // Only inject metadata — agent uses `read` tool to load full content on demand
            var prompt = "Skill: \(name)"
            if !description.isEmpty {
                prompt += "\nWhen to use: \(description)"
            }
            prompt += "\nFull instructions: use `read` tool on \(filePath)"

            skills.append(BasicSkill(name: name, systemPrompt: prompt))
        }

        return skills.sorted { $0.name < $1.name }
    }

    /// Parse YAML frontmatter delimited by `---` lines.
    /// Returns (name, description, body) or nil if no frontmatter found.
    static func parseFrontmatter(_ content: String) -> (name: String, description: String, body: String)? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else { return nil }

        // Find the closing ---
        let afterOpening = trimmed.dropFirst(3).drop(while: { $0.isNewline })
        guard let closeRange = afterOpening.range(of: "\n---") else { return nil }

        let yamlBlock = String(afterOpening[afterOpening.startIndex..<closeRange.lowerBound])
        let body = String(afterOpening[closeRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var name = ""
        var description = ""

        for line in yamlBlock.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("name:") {
                name = extractYAMLValue(trimmedLine, key: "name")
            } else if trimmedLine.hasPrefix("description:") {
                description = extractYAMLValue(trimmedLine, key: "description")
            }
        }

        return (name: name, description: description, body: body)
    }

    private static func extractYAMLValue(_ line: String, key: String) -> String {
        let afterKey = line.dropFirst(key.count + 1) // drop "key:"
        var value = afterKey.trimmingCharacters(in: .whitespaces)

        // Strip surrounding quotes
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }

        return value
    }
}
