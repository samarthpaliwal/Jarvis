import Foundation

/// Minimal Notion API client (integration token in Keychain as NOTION_TOKEN).
public final class NotionClient: @unchecked Sendable {
    public struct Page: Equatable, Sendable {
        public var id: String
        public var title: String
        public var url: String
        public var date: Date?          // first date property found (Due / Date)
        public var status: String?      // Status / Study Status
        public var location: String?
        public var relationIDs: [String] = []
        public var extra: [String: String] = [:]
    }

    public enum NotionError: LocalizedError {
        case noToken, http(Int, String), malformed
        public var errorDescription: String? {
            switch self {
            case .noToken: return "Notion isn't connected. Use Connect Notion… in the Jarvis menu."
            case .http(let c, let m): return "Notion error \(c): \(m)"
            case .malformed: return "Unexpected Notion response."
            }
        }
    }

    public static let tokenAccount = "NOTION_TOKEN"
    private let tokenProvider: () -> String?
    private let session: URLSession
    private var titleCache: [String: String] = [:]
    private let lock = NSLock()

    public init(tokenProvider: @escaping () -> String? = { KeychainStore.read(account: NotionClient.tokenAccount) },
                session: URLSession = .shared) {
        self.tokenProvider = tokenProvider
        self.session = session
    }

    public var isConfigured: Bool { tokenProvider() != nil }

    private func request(_ path: String, method: String = "POST", body: JSONObject? = nil) async throws -> JSONObject {
        guard let token = tokenProvider() else { throw NotionError.noToken }
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? JSONObject else { throw NotionError.malformed }
        guard code == 200 else { throw NotionError.http(code, obj["message"] as? String ?? "") }
        return obj
    }

    // MARK: Queries

    /// Rows of a data source, optionally filtered. `filter` is a raw Notion filter object.
    public func query(dataSource id: String, filter: JSONObject? = nil, sorts: [JSONObject] = [], pageSize: Int = 50) async throws -> [Page] {
        var body: JSONObject = ["page_size": pageSize]
        if let filter { body["filter"] = filter }
        if !sorts.isEmpty { body["sorts"] = sorts }
        let obj = try await request("data_sources/\(id)/query", body: body)
        return (obj["results"] as? [JSONObject] ?? []).map(Self.parsePage)
    }

    public func search(_ query: String, limit: Int = 10) async throws -> [Page] {
        let obj = try await request("search", body: ["query": query, "page_size": limit,
                                                      "filter": ["value": "page", "property": "object"]])
        return (obj["results"] as? [JSONObject] ?? []).map(Self.parsePage)
    }

    /// Title of a page by id, cached (used to resolve Class relations).
    public func pageTitle(_ id: String) async -> String? {
        if let cached = lock.withLock({ titleCache[id] }) { return cached }
        guard let obj = try? await request("pages/\(id)", method: "GET") else { return nil }
        let t = Self.parsePage(obj).title
        lock.withLock { titleCache[id] = t }
        return t
    }

    /// Creates a page. Parent: a page id or a data source id (`parentIsDataSource`).
    public func createPage(parentID: String, parentIsDataSource: Bool, title: String, body: String?, titleProperty: String = "title") async throws -> Page {
        var props: JSONObject = [titleProperty: ["title": [["text": ["content": title]]]]]
        if !parentIsDataSource { props = ["title": ["title": [["text": ["content": title]]]]] }
        var payload: JSONObject = [
            "parent": parentIsDataSource ? ["data_source_id": parentID] : ["page_id": parentID],
            "properties": props,
        ]
        if let body, !body.isEmpty {
            payload["children"] = body.split(separator: "\n").map { line in
                ["object": "block", "type": "paragraph",
                 "paragraph": ["rich_text": [["type": "text", "text": ["content": String(line.prefix(2000))]]]]]
            }
        }
        return Self.parsePage(try await request("pages", body: payload))
    }

    // MARK: Parsing

    static func parsePage(_ obj: JSONObject) -> Page {
        var page = Page(id: obj["id"] as? String ?? "", title: "", url: obj["url"] as? String ?? "")
        let props = obj["properties"] as? JSONObject ?? [:]
        for (name, raw) in props {
            guard let p = raw as? JSONObject, let type = p["type"] as? String else { continue }
            switch type {
            case "title":
                page.title = richText(p["title"])
            case "date":
                if page.date == nil, let d = p["date"] as? JSONObject, let s = d["start"] as? String {
                    page.date = parseDate(s)
                    page.extra["dateProperty"] = name
                }
            case "select", "status":
                let v = (p[type] as? JSONObject)?["name"] as? String
                if name.lowercased().contains("status") { page.status = v } else if let v { page.extra[name] = v }
            case "rich_text":
                let t = richText(p["rich_text"])
                if name.lowercased() == "location" { page.location = t } else if !t.isEmpty { page.extra[name] = t }
            case "relation":
                page.relationIDs += (p["relation"] as? [JSONObject] ?? []).compactMap { $0["id"] as? String }
            case "multi_select":
                page.extra[name] = (p["multi_select"] as? [JSONObject] ?? []).compactMap { $0["name"] as? String }.joined(separator: ",")
            case "number":
                if let n = p["number"] as? Double { page.extra[name] = String(n) }
            default: break
            }
        }
        if page.title.isEmpty { page.title = "(untitled)" }
        return page
    }

    static func richText(_ v: Any?) -> String {
        (v as? [JSONObject] ?? []).compactMap { $0["plain_text"] as? String }.joined()
    }

    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.date(from: s)
    }

    public static func dateString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.string(from: d)
    }
}
