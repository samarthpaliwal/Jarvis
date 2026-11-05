import Foundation

/// Tier 0: Gmail search.
public final class EmailSearchTool: JarvisTool {
    public let name = "email_search"
    public let description = "Search Gmail with Gmail query syntax (e.g. 'from:professor newer_than:7d', 'subject:exam', 'is:unread'). Returns id, from, subject, date, snippet for up to 10 messages."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": ["query": ["type": "string"], "limit": ["type": "integer", "minimum": 1, "maximum": 20]],
        "required": ["query"], "additionalProperties": false,
    ]
    private let gmail: GmailClient
    public init(gmail: GmailClient) { self.gmail = gmail }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let q = input.string("query") else { return .error("query is required") }
        let msgs = try await gmail.search(q, limit: input.int("limit") ?? 10)
        if msgs.isEmpty { return ToolResult("No emails match “\(q)”.") }
        let lines = msgs.map { "[\($0.id)] \($0.from) · \($0.subject) · \($0.date)\n  \($0.snippet)" }
        return ToolResult(Untrusted.wrap(lines.joined(separator: "\n"), source: "gmail"),
                          card: .info(title: "Mail: \(q)", lines: msgs.prefix(5).map { "\($0.subject) — \($0.from.prefix(30))" }))
    }
}

/// Tier 0: read one message.
public final class EmailReadTool: JarvisTool {
    public let name = "email_read"
    public let description = "Read the full text of one Gmail message by id (from email_search)."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = [
        "type": "object", "properties": ["id": ["type": "string"]], "required": ["id"], "additionalProperties": false,
    ]
    private let gmail: GmailClient
    public init(gmail: GmailClient) { self.gmail = gmail }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let id = input.string("id") else { return .error("id is required") }
        let m = try await gmail.message(id: id, full: true)
        var body = m.body
        if body.count > 8000 { body = String(body.prefix(8000)) + "\n…(truncated)" }
        let text = "From: \(m.from)\nTo: \(m.to)\nDate: \(m.date)\nSubject: \(m.subject)\n\n\(body)"
        return ToolResult(Untrusted.wrap(text, source: "gmail:\(m.id)"))
    }
}

/// Tier 1: draft only. Sending email is Tier 2 and is not implemented on purpose.
public final class EmailDraftTool: JarvisTool {
    public let name = "email_draft"
    public let description = "Create a Gmail DRAFT (never sends). Give to, subject, body; optionally reply_to_id to draft a reply in that thread. Sam reviews and sends it himself."
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": ["to": ["type": "string"], "subject": ["type": "string"], "body": ["type": "string"], "reply_to_id": ["type": "string"]],
        "required": ["to", "subject", "body"], "additionalProperties": false,
    ]
    private let gmail: GmailClient
    public init(gmail: GmailClient) { self.gmail = gmail }

    public func preview(for input: JSONObject) -> String { "draft to \(input.string("to") ?? "") “\(input.string("subject") ?? "")”" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let to = input.string("to"), let subject = input.string("subject"), let body = input.string("body") else {
            return .error("to, subject and body are required")
        }
        let replyTo = try await input.string("reply_to_id").asyncMap { try await gmail.message(id: $0, full: false) }
        let id = try await gmail.createDraft(to: to, subject: subject, body: body, inReplyTo: replyTo)
        let g = gmail
        await context.undo.push(.init(description: "draft “\(subject)”") { try await g.deleteDraft(id: id); return "Deleted the draft “\(subject)”." })
        return ToolResult("Draft saved in Gmail (not sent): to \(to), “\(subject)”.", summary: "Drafted “\(subject)” to \(to)")
    }
}

extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let v = self else { return nil }
        return try await f(v)
    }
}
