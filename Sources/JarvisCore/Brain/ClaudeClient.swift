import Foundation

/// Minimal streaming client for POST /v1/messages (no SDK exists for Swift).
public final class ClaudeClient: @unchecked Sendable {
    // @unchecked: serverBlock carries a JSON dictionary that is built once and never mutated after yielding.
    public enum Event: @unchecked Sendable {
        case textDelta(String)
        case blockStart(type: String)
        case toolUseStart(id: String, name: String)
        case toolInputDelta(String)
        case contentBlockStop
        case stopReason(String)
        case usage(input: Int, output: Int, cacheRead: Int, cacheWrite: Int)
        case refusal(String?)
        /// A complete server-side block (web_search / web_fetch call or result), kept verbatim for history.
        case serverBlock(JSONObject)
    }

    /// Per-stream state for blocks that must be reassembled (server tool calls and their results).
    final class StreamState {
        var block: JSONObject?
        var json = ""
    }

    /// Block types Jarvis handles itself; everything else in an assistant turn is a server-side block.
    static let clientBlockTypes: Set<String> = ["text", "tool_use", "thinking", "redacted_thinking"]

    public enum ClientError: LocalizedError {
        case noAPIKey
        case http(Int, String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .noAPIKey: return "No API key. Add it from the Jarvis menu (Set API Key…)."
            case .http(let code, let body):
                switch code {
                case 401: return "The API key was rejected (401)."
                case 429: return "Rate limited by the API (429). Try again in a moment."
                case 529: return "Claude is overloaded right now (529)."
                default: return "API error \(code): \(body.prefix(200))"
                }
            case .malformed(let why): return "Unexpected API response: \(why)"
            }
        }
    }

    public struct Request {
        public var model: String
        /// Stable instructions (cached) and per-turn context (not cached).
        public var system: String
        public var systemVolatile: String = ""
        public var messages: [JSONObject]
        public var tools: [JSONObject]
        public var maxTokens: Int
        public var effort: String
        public init(model: String, system: String, messages: [JSONObject], tools: [JSONObject], maxTokens: Int, effort: String = "low") {
            self.model = model; self.system = system; self.messages = messages; self.tools = tools
            self.maxTokens = maxTokens; self.effort = effort
        }
    }

    public var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let session: URLSession
    private let apiKeyProvider: () -> String?

    public init(apiKeyProvider: @escaping () -> String? = { KeychainStore.apiKey() }) {
        self.apiKeyProvider = apiKeyProvider
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 300
        session = URLSession(configuration: cfg)
    }

    public func body(for r: Request) -> JSONObject {
        var system: [JSONObject] = [["type": "text", "text": r.system, "cache_control": ["type": "ephemeral"]]]
        if !r.systemVolatile.isEmpty { system.append(["type": "text", "text": r.systemVolatile]) }
        var b: JSONObject = [
            "model": r.model,
            "max_tokens": r.maxTokens,
            "stream": true,
            "system": system,
            "messages": r.messages,
            "output_config": ["effort": r.effort],
        ]
        if !r.tools.isEmpty {
            // Tools render before system; a breakpoint on the last one caches the whole tool list.
            var tools = r.tools
            tools[tools.count - 1]["cache_control"] = ["type": "ephemeral"]
            b["tools"] = tools
        }
        // Sonnet 5.5 can skip reasoning between tool calls (lowest latency for a voice assistant).
        if r.model.hasPrefix("claude-sonnet-5-5") { b["thinking"] = ["type": "between_tools"] }
        return b
    }

    /// Streams SSE events. Throws on HTTP/API errors.
    public func stream(_ r: Request) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = apiKeyProvider() else { throw ClientError.noAPIKey }
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(key, forHTTPHeaderField: "x-api-key")
                    req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
                    req.httpBody = try JSONSerialization.data(withJSONObject: body(for: r))
                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else { throw ClientError.malformed("no HTTP response") }
                    if http.statusCode != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line }
                        throw ClientError.http(http.statusCode, Self.errorMessage(text))
                    }
                    // Anthropic emits one JSON object per `data:` line, so dispatch each line as it arrives
                    // (the line iterator may swallow the blank SSE separators).
                    let state = StreamState()
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if !payload.isEmpty { try Self.handle(payload, continuation, state) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func handleForTesting(_ payload: String, _ c: AsyncThrowingStream<Event, Error>.Continuation, _ state: StreamState = StreamState()) throws {
        try handle(payload, c, state)
    }

    private static func handle(_ payload: String, _ c: AsyncThrowingStream<Event, Error>.Continuation, _ state: StreamState) throws {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
              let type = obj["type"] as? String else { return }
        switch type {
        case "content_block_start":
            guard let block = obj["content_block"] as? JSONObject else { return }
            let type = block["type"] as? String ?? "?"
            c.yield(.blockStart(type: type))
            if !clientBlockTypes.contains(type) {
                // server_tool_use streams its input as JSON deltas; result blocks arrive whole here.
                state.block = block; state.json = ""
            } else if type == "tool_use", let id = block["id"] as? String, let name = block["name"] as? String {
                c.yield(.toolUseStart(id: id, name: name))
            } else if type == "text", let t = block["text"] as? String, !t.isEmpty {
                c.yield(.textDelta(t)) // some responses carry text on the start event
            }
        case "content_block_delta":
            guard let delta = obj["delta"] as? JSONObject else { return }
            let dtype = delta["type"] as? String ?? "?"
            if state.block != nil {
                if let j = delta["partial_json"] as? String { state.json += j }
                return
            }
            if let t = delta["text"] as? String, dtype == "text_delta" { c.yield(.textDelta(t)) }
            else if let j = delta["partial_json"] as? String { c.yield(.toolInputDelta(j)) }
            else if dtype != "thinking_delta" && dtype != "signature_delta" && dtype != "citations_delta" { c.yield(.blockStart(type: "delta:\(dtype)")) }
        case "content_block_stop":
            if var block = state.block {
                if !state.json.isEmpty, let input = try? JSONSerialization.jsonObject(with: Data(state.json.utf8)) as? JSONObject {
                    block["input"] = input
                }
                state.block = nil; state.json = ""
                c.yield(.serverBlock(block))
            }
            c.yield(.contentBlockStop)
        case "message_delta":
            if let delta = obj["delta"] as? JSONObject, let stop = delta["stop_reason"] as? String {
                if stop == "refusal" {
                    let details = delta["stop_details"] as? JSONObject
                    c.yield(.refusal(details?["category"] as? String))
                }
                c.yield(.stopReason(stop))
            }
            if let usage = obj["usage"] as? JSONObject {
                c.yield(.usage(input: usage["input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0,
                               cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0, cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0))
            }
        case "message_start":
            if let msg = obj["message"] as? JSONObject, let usage = msg["usage"] as? JSONObject {
                c.yield(.usage(input: usage["input_tokens"] as? Int ?? 0, output: 0,
                               cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0, cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0))
            }
        case "error":
            let err = obj["error"] as? JSONObject
            throw ClientError.http(500, (err?["message"] as? String) ?? "stream error")
        default:
            break
        }
    }

    private static func errorMessage(_ body: String) -> String {
        if let d = body.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? JSONObject,
           let e = o["error"] as? JSONObject, let m = e["message"] as? String { return m }
        return body
    }
}
