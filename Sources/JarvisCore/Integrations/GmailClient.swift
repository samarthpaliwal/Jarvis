import Foundation

/// Gmail REST: search, read, draft. Sending is deliberately not implemented in this client.
public final class GmailClient: @unchecked Sendable {
    public struct Message: Equatable, Sendable {
        public var id: String
        public var threadId: String
        public var from: String
        public var to: String
        public var subject: String
        public var date: String
        public var snippet: String
        public var body: String
        public var labels: [String]
    }

    private let auth: GoogleAuth
    public init(auth: GoogleAuth) { self.auth = auth }
    public var isConnected: Bool { auth.isConnected }

    private func get(_ path: String, query: [String: String] = [:]) async throws -> JSONObject {
        let token = try await auth.token()
        var comps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? JSONObject) ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw GoogleAuth.AuthError.server("HTTP \(code) \((obj["error"] as? JSONObject)?["message"] as? String ?? "")") }
        return obj
    }

    public func search(_ q: String, limit: Int = 10) async throws -> [Message] {
        let list = try await get("messages", query: ["q": q, "maxResults": String(limit)])
        let ids = (list["messages"] as? [JSONObject] ?? []).compactMap { $0["id"] as? String }
        // Fetch message headers in parallel (was one request at a time: ~9 s for 10 emails).
        let fetched = await withTaskGroup(of: (Int, Message?).self) { group in
            for (i, id) in ids.enumerated() {
                group.addTask { (i, try? await self.message(id: id, full: false)) }
            }
            var acc: [(Int, Message?)] = []
            for await r in group { acc.append(r) }
            return acc
        }
        return fetched.sorted { $0.0 < $1.0 }.compactMap(\.1)   // keep Gmail's newest-first order
    }

    public func message(id: String, full: Bool) async throws -> Message {
        let obj = try await get("messages/\(id)", query: ["format": full ? "full" : "metadata"])
        return Self.parse(obj)
    }

    /// Creates a draft (never sends). Returns the draft id.
    public func createDraft(to: String, subject: String, body: String, inReplyTo: Message? = nil) async throws -> String {
        let token = try await auth.token()
        var headers = "To: \(to)\r\nSubject: \(subject)\r\nContent-Type: text/plain; charset=utf-8\r\n"
        if let r = inReplyTo { headers += "In-Reply-To: \(r.id)\r\nReferences: \(r.id)\r\n" }
        let raw = Data((headers + "\r\n" + body).utf8).base64URL()
        var payload: JSONObject = ["message": ["raw": raw]]
        if let r = inReplyTo { payload["message"] = ["raw": raw, "threadId": r.threadId] }
        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/drafts")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? JSONObject) ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let id = obj["id"] as? String else {
            throw GoogleAuth.AuthError.server("draft failed: \((obj["error"] as? JSONObject)?["message"] as? String ?? "")")
        }
        return id
    }

    public func deleteDraft(id: String) async throws {
        let token = try await auth.token()
        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/drafts/\(id)")!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: req)
    }

    // MARK: Parsing

    static func parse(_ obj: JSONObject) -> Message {
        let payload = obj["payload"] as? JSONObject ?? [:]
        let headers = (payload["headers"] as? [JSONObject] ?? []).reduce(into: [String: String]()) { acc, h in
            if let n = h["name"] as? String, let v = h["value"] as? String { acc[n.lowercased()] = v }
        }
        return Message(id: obj["id"] as? String ?? "", threadId: obj["threadId"] as? String ?? "",
                       from: headers["from"] ?? "", to: headers["to"] ?? "", subject: headers["subject"] ?? "(no subject)",
                       date: headers["date"] ?? "", snippet: obj["snippet"] as? String ?? "",
                       body: textBody(payload), labels: obj["labelIds"] as? [String] ?? [])
    }

    /// Prefers text/plain parts; falls back to stripped text/html.
    static func textBody(_ part: JSONObject) -> String {
        if let plain = findPart(part, mime: "text/plain") { return plain }
        if let html = findPart(part, mime: "text/html") { return stripHTML(html) }
        return ""
    }

    static func findPart(_ part: JSONObject, mime: String) -> String? {
        if part["mimeType"] as? String == mime, let body = part["body"] as? JSONObject, let d = body["data"] as? String,
           let data = Data(base64URL: d), let s = String(data: data, encoding: .utf8) { return s }
        for p in part["parts"] as? [JSONObject] ?? [] {
            if let s = findPart(p, mime: mime) { return s }
        }
        return nil
    }

    static func stripHTML(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<(script|style)[^>]*>[\s\S]*?</\1>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<br\s*/?>|</p>|</div>|</tr>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
