import Foundation

/// Agent skills in the agentskills.io SKILL.md format (as used by OpenJarvis, Hermes, OpenClaw):
/// a folder with SKILL.md whose YAML front matter has `name` and `description`, followed by
/// instructions. The catalog goes in the system prompt; `use_skill` loads the body on demand.
/// Skills are instructions only: every tool they lead to still goes through the permission dispatcher.
public final class SkillLibrary: @unchecked Sendable {
    public struct Skill: Equatable, Sendable { public var name: String; public var description: String; public var body: String; public var folder: URL }

    public let directory: URL
    private var skills: [String: Skill] = [:]
    private let lock = NSLock()

    public init(directory: URL = ConfigLocator.userConfigDirectory.deletingLastPathComponent().appendingPathComponent("skills", isDirectory: true)) {
        self.directory = directory
        reload()
    }

    public func reload() {
        var found: [String: Skill] = [:]
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            let md = folder.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: md, encoding: .utf8), let s = Self.parse(text, folder: folder) else { continue }
            found[s.name.lowercased()] = s
        }
        lock.withLock { skills = found }
    }

    public var all: [Skill] { lock.withLock { skills.values.sorted { $0.name < $1.name } } }
    public func skill(named n: String) -> Skill? { lock.withLock { skills[n.lowercased()] } }

    public var catalog: String? {
        let list = all
        guard !list.isEmpty else { return nil }
        return "Skills you can load with use_skill when relevant:\n" + list.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
    }

    /// Parses `---\nname: x\ndescription: y\n---\nbody`. Name falls back to the folder name.
    public static func parse(_ text: String, folder: URL) -> Skill? {
        var name = folder.lastPathComponent, desc = "", body = text
        if text.hasPrefix("---") {
            let parts = text.components(separatedBy: "\n---")
            if parts.count >= 2 {
                for line in parts[0].split(separator: "\n").dropFirst() {
                    let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard kv.count == 2 else { continue }
                    let v = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if kv[0] == "name" { name = v } else if kv[0] == "description" { desc = v }
                }
                body = parts.dropFirst().joined(separator: "\n---").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !body.isEmpty else { return nil }
        return Skill(name: name, description: desc.isEmpty ? String(body.prefix(100)) : desc, body: body, folder: folder)
    }
}

/// Tier 0: load a skill's instructions into the conversation.
public final class UseSkillTool: JarvisTool {
    public let name = "use_skill"
    public let description = "Load the full instructions of an installed skill by name (see the skills list in your instructions), then follow them."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"], "additionalProperties": false]
    private let library: SkillLibrary
    public init(library: SkillLibrary) { self.library = library }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let n = input.string("name"), let s = library.skill(named: n) else {
            return .error("No skill called \(input.string("name") ?? "?"). Installed: \(library.all.map(\.name).joined(separator: ", "))")
        }
        let body = s.body.count > 12_000 ? String(s.body.prefix(12_000)) + "\n…(truncated)" : s.body
        return ToolResult("<skill name=\"\(s.name)\">\n\(body)\n</skill>\nFollow these instructions. Permission tiers still apply to every tool you use.")
    }
}
