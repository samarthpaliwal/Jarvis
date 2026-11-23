import Foundation

/// Local model via Ollama (OpenJarvis's local-first engine). Used when the Mac is offline, or for
/// every turn in Private Mode. Talks to http://127.0.0.1:11434/api/chat with tool calling.
public final class OllamaClient: @unchecked Sendable {
    public struct Reply: @unchecked Sendable {
        public var text: String
        public var toolCalls: [(name: String, arguments: JSONObject)]
        public init(text: String, toolCalls: [(name: String, arguments: JSONObject)]) { self.text = text; self.toolCalls = toolCalls }
    }

    public var baseURL: URL
    public var model: String
    private let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, model: String) {
        self.baseURL = baseURL
        self.model = model
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        cfg.connectionProxyDictionary = [:] // never route localhost through a proxy
        session = URLSession(configuration: cfg)
    }

    /// True when the server answers and the configured model is pulled.
    public func status() async -> (running: Bool, hasModel: Bool, models: [String]) {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 1.5
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? JSONObject else { return (false, false, []) }
        let names = (obj["models"] as? [JSONObject] ?? []).compactMap { $0["name"] as? String }
        let base = model.split(separator: ":").first.map(String.init) ?? model
        let has = names.contains(model) || names.contains("\(model):latest") || (!model.contains(":") && names.contains { $0.hasPrefix(base + ":") })
        return (true, has, names)
    }

    /// Anthropic-style tool definitions → Ollama/OpenAI function tools.
    public static func tools(from defs: [JSONObject]) -> [JSONObject] {
        defs.map { d in
            ["type": "function", "function": ["name": d["name"] ?? "", "description": d["description"] ?? "", "parameters": d["input_schema"] ?? ["type": "object"]]]
        }
    }

    public func body(messages: [JSONObject], tools: [JSONObject]) -> JSONObject {
        var b: JSONObject = ["model": model, "messages": messages, "stream": true, "options": ["temperature": 0.4, "num_ctx": 8192], "keep_alive": "10m"]
        if !tools.isEmpty { b["tools"] = tools }
        return b
    }

    /// Streams one assistant message. Text deltas go to `onText`; tool calls arrive at the end.
    public func chat(messages: [JSONObject], tools: [JSONObject], onText: @escaping (String) -> Void) async throws -> Reply {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body(messages: messages, tools: tools))
        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            var t = ""; for try await l in bytes.lines { t += l }
            throw NSError(domain: "Jarvis.Ollama", code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: "Local model error: \(t.prefix(200))"])
        }
        var reply = Reply(text: "", toolCalls: [])
        for try await line in bytes.lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSONObject else { continue }
            if let err = obj["error"] as? String { throw NSError(domain: "Jarvis.Ollama", code: 1, userInfo: [NSLocalizedDescriptionKey: err]) }
            let msg = obj["message"] as? JSONObject ?? [:]
            if let t = msg["content"] as? String, !t.isEmpty { reply.text += t; onText(t) }
            for call in msg["tool_calls"] as? [JSONObject] ?? [] {
                let fn = call["function"] as? JSONObject ?? [:]
                var args = fn["arguments"] as? JSONObject ?? [:]
                if args.isEmpty, let s = fn["arguments"] as? String, let parsed = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? JSONObject { args = parsed }
                if let name = fn["name"] as? String { reply.toolCalls.append((name, args)) }
            }
        }
        return reply
    }
}
