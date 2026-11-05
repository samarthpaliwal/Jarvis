import Foundation

/// Tier 0: search Notion pages.
public final class NotionSearchTool: JarvisTool {
    public let name = "notion_search"
    public let description = "Search Sam's Notion workspace (Student OS: classes, homework, exams, notes) by keywords. Returns titles, dates, statuses, and URLs."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": ["query": ["type": "string"]],
        "required": ["query"], "additionalProperties": false,
    ]
    private let client: NotionClient
    public init(client: NotionClient) { self.client = client }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let q = input.string("query"), !q.isEmpty else { return .error("query is required") }
        let pages = try await client.search(q)
        if pages.isEmpty { return ToolResult("No Notion pages match “\(q)”.") }
        let f = DateFormatter(); f.dateStyle = .medium
        let lines = pages.map { p in
            var s = p.title
            if let d = p.date { s += " · \(f.string(from: d))" }
            if let st = p.status { s += " · \(st)" }
            return s
        }
        return ToolResult(Untrusted.wrap(lines.joined(separator: "\n"), source: "notion"),
                          card: .info(title: "Notion: \(q)", lines: Array(lines.prefix(5))))
    }
}

/// Tier 1: create a note page in Notion (under the configured notes parent, or a named parent page).
public final class NotionCreateNoteTool: JarvisTool {
    public let name = "notion_create_note"
    public let description = "Create a Notion page with a title and body text under Sam's notes parent (or add a homework/exam row when target is 'homework' or 'exams')."
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "body": ["type": "string"],
            "target": ["type": "string", "enum": ["notes", "homework", "exams"], "description": "Default notes"],
            "date": ["type": "string", "description": "YYYY-MM-DD for homework due / exam date"],
        ],
        "required": ["title"], "additionalProperties": false,
    ]
    private let client: NotionClient
    public init(client: NotionClient) { self.client = client }

    public func preview(for input: JSONObject) -> String { "Notion note “\(input.string("title") ?? "")”" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let title = input.string("title"), !title.isEmpty else { return .error("title is required") }
        let notion = await context.config.profile.dataSources.notion
        let target = input.string("target") ?? "notes"
        let page: NotionClient.Page
        switch target {
        case "homework", "exams":
            let ds = target == "homework" ? notion.homeworkDataSourceId : notion.examsDataSourceId
            guard !ds.isEmpty else { return .error("No Notion \(target) database configured in profile.json.") }
            let titleProp = target == "homework" ? notion.homeworkTitleProperty : notion.examsTitleProperty
            page = try await client.createPage(parentID: ds, parentIsDataSource: true, title: title, body: input.string("body"), titleProperty: titleProp)
            if let date = input.string("date") {
                let dateProp = target == "homework" ? notion.homeworkDueProperty : notion.examsDateProperty
                _ = try? await client.setDate(pageID: page.id, property: dateProp, date: date)
            }
        default:
            guard !notion.notesParentPageId.isEmpty else {
                return .error("No notes parent page configured (profile.json → dataSources.notion.notesParentPageId).")
            }
            page = try await client.createPage(parentID: notion.notesParentPageId, parentIsDataSource: false, title: title, body: input.string("body"))
        }
        return ToolResult("Created “\(title)” in Notion (\(target)).", summary: "Notion: created “\(title)”")
    }
}

extension NotionClient {
    /// Sets a date property on a page (used after creating homework/exam rows).
    public func setDate(pageID: String, property: String, date: String) async throws {
        guard let token = KeychainStore.read(account: NotionClient.tokenAccount) else { throw NotionError.noToken }
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/pages/\(pageID)")!)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["properties": [property: ["date": ["start": date]]]])
        _ = try await URLSession.shared.data(for: req)
    }
}
