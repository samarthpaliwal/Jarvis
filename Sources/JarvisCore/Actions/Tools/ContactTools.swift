import Foundation

/// Tier 1: look people up and remember them. Saved contacts live on this Mac only.
public final class ContactsTool: JarvisTool {
    public let name = "contacts"
    public let description = "People Sam deals with. find: look someone up by name or by how Sam refers to them ('Maya', 'my lab partner'); checks saved contacts first, then macOS Contacts. save: remember a person (name required; email, phone, relationship, notes optional), or add details to someone already saved. remove / list: saved contacts only. ALWAYS use find before drafting an email or message to a named person, and never guess an address: if nothing is found, ask Sam for it, then save it."
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["find", "save", "remove", "list"]],
            "name": ["type": "string", "description": "A name, or for find a relationship such as 'lab partner'."],
            "email": ["type": "string"],
            "phone": ["type": "string"],
            "relationship": ["type": "string", "description": "How Sam refers to them: 'lab partner', 'mom', 'CSC 120 professor'."],
            "notes": ["type": "string"],
        ],
        "required": ["action"], "additionalProperties": false,
    ]
    private let book: ContactBook
    public init(book: ContactBook) { self.book = book }

    public func preview(for input: JSONObject) -> String { "contacts \(input.string("action") ?? "") \(input.string("name") ?? "")" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let name = input.string("name") ?? ""
        switch input.string("action") ?? "find" {
        case "find":
            guard !name.isEmpty else { return .error("name is required for find") }
            let hits = await book.find(name)
            if hits.isEmpty { return ToolResult("No contact found for “\(name)”. Ask Sam for the address, then save it. Do not guess one.") }
            return ToolResult(hits.map { "- " + $0.line }.joined(separator: "\n"))
        case "save":
            let saved = try book.save(Contact(name: name, email: input.string("email"), phone: input.string("phone"),
                                              relationship: input.string("relationship"), notes: input.string("notes")))
            let b = book
            await context.undo.push(.init(description: "saved contact “\(saved.name)”") { try b.remove(matching: saved.name); return "Removed \(saved.name) from contacts." })
            return ToolResult("Saved: \(saved.line)", summary: "Contact saved: \(saved.name)")
        case "remove":
            let removed = try book.remove(matching: name)
            let b = book
            await context.undo.push(.init(description: "removed contact “\(removed.name)”") { try b.save(removed); return "Restored \(removed.name)." })
            return ToolResult("Removed \(removed.name).", summary: "Contact removed: \(removed.name)")
        case "list":
            let all = book.all
            return ToolResult(all.isEmpty ? "No saved contacts yet." : all.map { "- " + $0.line }.joined(separator: "\n"))
        default:
            return .error("action must be find, save, remove, or list")
        }
    }
}
