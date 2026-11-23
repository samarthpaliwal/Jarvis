import Foundation

/// Tier 1: read / add / update / remove persistent memories (adapted from OpenJarvis memory_manage + user_profile_manage).
public final class MemoryTool: JarvisTool {
    public let name = "memory"
    public let description = "Persistent memory that survives restarts. scope 'profile' = Sam's preferences and personal facts (\"prefers Celsius\", \"lab partner is Maya\"); scope 'facts' = everything else worth keeping (\"CSC 210 lab is Gould-Simpson 701\"). Actions: read, add, update (entry = text to find, new_entry = replacement), remove. Save only lasting, useful things Sam tells you or asks you to remember. Never store passwords, keys, or card numbers."
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["read", "add", "update", "remove"]],
            "scope": ["type": "string", "enum": ["facts", "profile"], "description": "Default facts"],
            "entry": ["type": "string"],
            "new_entry": ["type": "string"],
        ],
        "required": ["action"], "additionalProperties": false,
    ]
    private let store: MemoryStore
    public init(store: MemoryStore) { self.store = store }
    public func preview(for input: JSONObject) -> String { "memory \(input.string("action") ?? "") \(input.string("entry") ?? "")" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let scope = MemoryStore.Scope(rawValue: input.string("scope") ?? "facts") ?? .facts
        let entry = input.string("entry") ?? ""
        switch input.string("action") ?? "read" {
        case "read":
            let list = store.entries(scope)
            return ToolResult(list.isEmpty ? "Nothing in \(scope.rawValue) yet." : list.map { "- \($0)" }.joined(separator: "\n"))
        case "add":
            try store.add(entry, to: scope)
            let s = store
            await context.undo.push(.init(description: "remembered “\(entry.prefix(40))”") { try s.remove(matching: entry, from: scope); return "Forgot it." })
            return ToolResult("Remembered.", summary: "Remembered: \(entry.prefix(60))")
        case "update":
            guard let new = input.string("new_entry") else { return .error("new_entry is required for update") }
            let old = try store.update(matching: entry, with: new, in: scope)
            return ToolResult("Updated “\(old)” → “\(new)”.", summary: "Memory updated")
        case "remove":
            let removed = try store.remove(matching: entry, from: scope)
            let s = store
            await context.undo.push(.init(description: "forgot “\(removed.prefix(40))”") { try s.add(removed, to: scope); return "Remembered it again." })
            return ToolResult("Forgot “\(removed)”.", summary: "Forgot: \(removed.prefix(60))")
        default:
            return .error("action must be read, add, update or remove")
        }
    }
}

/// Tier 0: search past conversations and saved notes.
public final class MemorySearchTool: JarvisTool {
    public let name = "memory_search"
    public let description = "Search Jarvis's long-term memory: past conversations with Sam and saved notes. Use for 'what did I ask you about…', 'when did I mention…', 'what did we decide about…'. Empty query returns the most recent conversations."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = ["type": "object", "properties": ["query": ["type": "string"]], "additionalProperties": false]
    private let store: MemoryStore
    public init(store: MemoryStore) { self.store = store }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let q = input.string("query") ?? ""
        let hits = q.isEmpty ? store.recentConversations() : store.search(q)
        if hits.isEmpty { return ToolResult("Nothing in memory matches “\(q)”.") }
        let f = DateFormatter(); f.dateFormat = "EEE MMM d, h:mm a"
        let text = hits.map { "[\(f.string(from: $0.date)) · \($0.kind)] \($0.text.prefix(500))" }.joined(separator: "\n\n")
        return ToolResult(Untrusted.wrap(text, source: "memory"))
    }
}
