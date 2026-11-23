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
    /// Set for Ollama's hosted models (ollama.com): the key sent with every request. Nil for a local server.
    public var apiKey: (@Sendable () -> String?)?
    /// Tokens the last reply used, when the server reported them.
    public private(set) var lastUsage: (input: Int, output: Int) = (0, 0)
    private let session: URLSession

    /// True when this client talks to a model running somewhere else, not on this Mac.
    public var isHosted: Bool { apiKey != nil }

    public static let hostedKeyAccount = "OLLAMA_API_KEY"

    /// A model hosted by Ollama (for example gpt-oss:120b). Nothing is installed or started on this Mac.
    public static func hosted(baseURL: URL = URL(string: "https://ollama.com")!, model: String,
                              apiKey: @escaping @Sendable () -> String? = { KeychainStore.read(account: OllamaClient.hostedKeyAccount) }) -> OllamaClient {
        let c = OllamaClient(baseURL: baseURL, model: model)
        c.apiKey = apiKey
        return c
    }

    /// Ready to answer: a key is saved. (A hosted model needs no download, so there is nothing else to check.)
    public var hasKey: Bool { !(apiKey?() ?? "").isEmpty }

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
        var b: JSONObject = ["model": model, "messages": messages, "stream": true]
        if isHosted { b["options"] = ["temperature": 0.4] }
        else { b["options"] = ["temperature": 0.4, "num_ctx": 8192]; b["keep_alive"] = "10m" }   // local: bound memory, stay loaded
        if !tools.isEmpty { b["tools"] = tools }
        return b
    }

    /// The chat request, ready to send. Hosted models carry the key; a local server gets none.
    public func request(messages: [JSONObject], tools: [JSONObject]) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            guard let key = apiKey(), !key.isEmpty else {
                throw NSError(domain: "Jarvis.Ollama", code: 401, userInfo: [NSLocalizedDescriptionKey: "No Ollama API key. Add it from the Jarvis menu (Brain → Set Ollama API Key…)."])
            }
            // The key only ever goes to the host it was configured for, over TLS.
            guard baseURL.scheme == "https" else {
                throw NSError(domain: "Jarvis.Ollama", code: 400, userInfo: [NSLocalizedDescriptionKey: "The hosted model address must be https."])
            }
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body(messages: messages, tools: tools))
        return req
    }

    /// Streams one assistant message. Text deltas go to `onText`; tool calls arrive at the end.
    public func chat(messages: [JSONObject], tools: [JSONObject], onText: @escaping (String) -> Void) async throws -> Reply {
        let req = try request(messages: messages, tools: tools)
        let (bytes, resp) = try await session.bytes(for: req)
        let http = resp as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            var t = ""; for try await l in bytes.lines { t += l }
            throw NSError(domain: "Jarvis.Ollama", code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: "\(isHosted ? "Hosted" : "Local") model error (\(http?.statusCode ?? 0)): \(t.prefix(200))"])
        }
        var reply = Reply(text: "", toolCalls: [])
        for try await line in bytes.lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSONObject else { continue }
            if let err = obj["error"] as? String { throw NSError(domain: "Jarvis.Ollama", code: 1, userInfo: [NSLocalizedDescriptionKey: err]) }
            if obj["done"] as? Bool == true {
                lastUsage = ((obj["prompt_eval_count"] as? Int) ?? 0, (obj["eval_count"] as? Int) ?? 0)
            }
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
