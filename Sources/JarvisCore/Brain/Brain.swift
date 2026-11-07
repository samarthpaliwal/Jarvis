import Foundation
import Network

/// The agent loop: user text → Claude (streaming) → tools via the dispatcher → more Claude → reply.
/// Keeps a short conversation history that expires after a few idle minutes.
@MainActor
public final class Brain: ObservableObject {
    public struct Turn {
        public var text = ""
        public var cards: [NotchCard] = []
        public var toolCalls: [String] = []
        public var inputTokens = 0
        public var outputTokens = 0
        public var cacheReadTokens = 0
        public var cacheWriteTokens = 0
        public var refused = false
        /// "claude", "local", or "offline-matcher".
        public var engine = "claude"
    }

    public let client: ClaudeClient
    public let dispatcher: ToolDispatcher
    private let config: ConfigStore
    private let modes: ModeManager
    private let undo: UndoStack

    private var history: [JSONObject] = []
    /// Incremented per cloud turn; only the newest turn may write `history`.
    private var generation = 0
    private var lastActivity = Date.distantPast
    private let historyTimeout: TimeInterval = 10 * 60
    private let maxHistoryMessages = 24
    private let maxToolRounds = 6

    @Published public private(set) var isOnline = true
    private let pathMonitor = NWPathMonitor()
    public var memory: MemoryStore?
    public var skills: SkillLibrary?
    public var local: OllamaClient?
    /// Private Mode: every turn goes to the local model, nothing to the cloud.
    @Published public var privateMode: Bool = UserDefaults.standard.bool(forKey: "jarvis.privateMode") {
        didSet { UserDefaults.standard.set(privateMode, forKey: "jarvis.privateMode") }
    }
    /// Tools a small local model gets (a short list keeps it accurate).
    static let localToolNames: Set<String> = ["system_status", "open_app", "set_volume", "music", "set_timer", "set_reminder",
                                              "calendar_read", "calendar_create", "get_briefing", "set_mode", "undo_last_action",
                                              "memory", "memory_search", "file_search", "set_brightness", "set_display_mode", "welcome_home"]

    public var model: String {
        ProcessInfo.processInfo.environment["CLAUDE_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? config.profile.claude.model
    }

    public init(client: ClaudeClient = ClaudeClient(), dispatcher: ToolDispatcher, config: ConfigStore, modes: ModeManager, undo: UndoStack) {
        self.client = client
        self.dispatcher = dispatcher
        self.config = config
        self.modes = modes
        self.undo = undo
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isOnline = path.status == .satisfied }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.samarth.jarvis.network"))
    }

    /// Called when the Jarvis card goes away: the next conversation starts fresh.
    /// Nothing is lost: every exchange is already in conversations.log and memory.db.
    public func endSession() {
        guard !history.isEmpty else { return }
        JarvisLog.info("Chat ended: cleared \(history.count) message(s) from the active conversation (kept in conversations.log)")
        history.removeAll()
        generation += 1
    }

    public func clearHistory() {
        history.removeAll()
        JarvisLog.info("Conversation history cleared")
    }

    /// Streams the reply text through `onText` as it arrives; returns the full turn when done.
    public func respond(to userText: String, onText: @escaping (String) -> Void) async throws -> Turn {
        do {
            return try await respondOnce(to: userText, onText: onText)
        } catch ClaudeClient.ClientError.http(400, let msg) {
            // Never leave Sam stuck behind a bad history: forget it and try once more.
            JarvisLog.warn("400 from Claude (\(msg.prefix(120))); clearing conversation history and retrying once")
            history.removeAll()
            return try await respondOnce(to: userText, onText: onText)
        }
    }

    private func respondOnce(to userText: String, onText: @escaping (String) -> Void) async throws -> Turn {
        if Date().timeIntervalSince(lastActivity) > historyTimeout { history.removeAll() }
        lastActivity = Date()
        var turn = Turn()

        let useLocal = privateMode || !isOnline
        if useLocal {
            if config.profile.local?.enabled ?? true, let local, await local.status().hasModel {
                turn = try await respondLocally(userText, client: local, onText: onText)
                memory?.archive(user: userText, jarvis: turn.text, tools: turn.toolCalls)
                return turn
            }
            if privateMode && isOnline {
                let msg = "Private Mode needs the local model. Start Ollama and pull \(config.profile.local?.model ?? "qwen3.5:9b"), or turn Private Mode off."
                turn.text = msg; turn.engine = "none"; onText(msg)
                return turn
            }
            turn.text = try await LocalFallback.handle(userText, dispatcher: dispatcher, modes: modes)
            turn.engine = "offline-matcher"
            onText(turn.text)
            return turn
        }

        generation += 1
        let myGeneration = generation
        var convo = Self.trimmed(Self.sanitized(history) + [["role": "user", "content": userText]], max: maxHistoryMessages)
        defer {
            // A newer turn may have started while this one awaited the network or a tool; only the
            // latest turn writes history, and always as a complete tool_use/tool_result sequence.
            if myGeneration == generation { history = Self.sanitized(convo) }
        }
        let mode = modes.current
        var (stable, volatile) = SystemPrompt.parts(profile: config.profile, mode: mode, online: isOnline, undoAvailable: undo.lastDescription)
        if let catalog = skills?.catalog { stable += "\n\n" + catalog }          // changes only when skills are installed
        if config.profile.memory?.enabled ?? true, let block = memory?.promptBlock() { volatile = block + "\n\n" + volatile }
        // Web tools first so the cache breakpoint stays on the last custom tool.
        let tools = Self.webTools(model: model, profile: config.profile, mode: mode) + dispatcher.definitions(for: mode)
        var guardian = LoopGuard()
        defer { if config.profile.memory?.archiveConversations ?? true { memory?.archive(user: userText, jarvis: turn.text, tools: turn.toolCalls) } }

        for round in 0...maxToolRounds {
            convo = Self.sanitized(convo)
            var request = ClaudeClient.Request(model: model, system: stable, messages: convo, tools: tools,
                                               maxTokens: config.profile.claude.maxTokens, effort: "low")
            request.systemVolatile = volatile
            var assistantContent: [JSONObject] = []
            var currentText = ""
            var currentTool: (id: String, name: String, json: String)?
            var stopReason = "end_turn"
            var blockTypes: [String] = []
            var needsGap = false   // text resuming after a web search needs a space ("Checking now. The…")

            let events = client.stream(request)
            do {
            for try await event in events {
                switch event {
                case .blockStart(let type):
                    blockTypes.append(type)
                case .textDelta(var t):
                    if needsGap {
                        needsGap = false
                        if let last = turn.text.last, !last.isWhitespace, t.first.map({ !$0.isWhitespace }) ?? false { t = " " + t }
                    }
                    currentText += t
                    turn.text += t
                    onText(t)
                case .toolUseStart(let id, let name):
                    if !currentText.isEmpty { assistantContent.append(["type": "text", "text": currentText]); currentText = "" }
                    currentTool = (id, name, "")
                case .toolInputDelta(let j):
                    currentTool?.json += j
                case .contentBlockStop:
                    if let t = currentTool {
                        let jsonText = t.json.isEmpty ? "{}" : t.json
                        let input = (try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? JSONObject) ?? [:]
                        assistantContent.append(["type": "tool_use", "id": t.id, "name": t.name, "input": input])
                        currentTool = nil
                    } else if !currentText.isEmpty {
                        assistantContent.append(["type": "text", "text": currentText]); currentText = ""
                    }
                case .stopReason(let s):
                    stopReason = s
                case .usage(let i, let o, let cr, let cw):
                    turn.inputTokens += i; turn.outputTokens += o; turn.cacheReadTokens += cr; turn.cacheWriteTokens += cw
                case .refusal(let category):
                    turn.refused = true
                    JarvisLog.warn("Claude refused (category: \(category ?? "unknown"))")
                case .serverBlock(let block):
                    // Web search/fetch ran on Anthropic's side: keep the block verbatim so the next
                    // request carries the call and its results exactly as the API sent them.
                    if !currentText.isEmpty { assistantContent.append(["type": "text", "text": currentText]); currentText = "" }
                    assistantContent.append(block)
                    needsGap = true
                    if block["type"] as? String == "server_tool_use" {
                        let name = block["name"] as? String ?? "server_tool"
                        let input = block["input"] as? JSONObject ?? [:]
                        turn.toolCalls.append(name)
                        dispatcher.recordServerTool(name, input: input)
                        JarvisLog.info("Server tool \(name): \(input["query"] as? String ?? input["url"] as? String ?? "")")
                    }
                }
            }
            } catch let e as ClaudeClient.ClientError {
                if case .http(400, _) = e { JarvisLog.error("400 request shape: \(Self.describe(convo))") }
                throw e
            }
            if !currentText.isEmpty { assistantContent.append(["type": "text", "text": currentText]) }
            JarvisLog.info("Claude round \(round): stop=\(stopReason) blocks=\(blockTypes) text=\(currentText.count + assistantContent.compactMap { ($0["text"] as? String)?.count }.reduce(0, +)) chars")
            if assistantContent.isEmpty {
                // Empty reply (cut off, refused, or nothing to say): don't poison the history with an empty block.
                JarvisLog.warn("Claude returned no content (stop: \(stopReason)); dropping this exchange from history")
                convo.removeLast() // the user message we just added, or the tool results
                if turn.text.isEmpty && !turn.refused { turn.text = "Sorry, I lost that one. Say it again?"; onText(turn.text) }
                return turn
            }
            convo.append(["role": "assistant", "content": assistantContent])

            let toolUses = assistantContent.filter { $0["type"] as? String == "tool_use" }
            if turn.refused {
                let msg = "I can't help with that one."
                if turn.text.isEmpty { turn.text = msg; onText(msg) }
                return turn
            }
            // A long server-side search loop pauses; re-send as-is and the API resumes it.
            if stopReason == "pause_turn" { continue }
            guard stopReason == "tool_use", !toolUses.isEmpty else { return turn }
            guard round < maxToolRounds else {
                let msg = " I've hit my tool limit for this request."
                turn.text += msg; onText(msg)
                return turn
            }

            // Run every requested tool, then return all results in ONE user message.
            var results: [JSONObject] = []
            for use in toolUses {
                let name = use["name"] as? String ?? ""
                let input = use["input"] as? JSONObject ?? [:]
                turn.toolCalls.append(name)
                if let loop = guardian.check(tool: name, input: input) {
                    JarvisLog.warn("LoopGuard: \(loop)")
                    results.append(["type": "tool_result", "tool_use_id": use["id"] as? String ?? "", "content": loop, "is_error": true])
                    continue
                }
                let result = await dispatcher.call(name, input: input, source: .user)
                if let card = result.card { turn.cards.append(card) }
                results.append(["type": "tool_result", "tool_use_id": use["id"] as? String ?? "",
                                "content": result.content, "is_error": result.isError])
            }
            convo.append(["role": "user", "content": results])
            if Task.isCancelled { return turn }   // results are recorded, so the history stays valid
        }
        return turn
    }

    // MARK: Local model (Ollama)

    func respondLocally(_ userText: String, client: OllamaClient, onText: @escaping (String) -> Void) async throws -> Turn {
        var turn = Turn()
        turn.engine = "local"
        let mode = modes.current
        var (stable, volatile) = SystemPrompt.parts(profile: config.profile, mode: mode, online: isOnline, undoAvailable: undo.lastDescription)
        if let block = memory?.promptBlock() { volatile = block + "\n\n" + volatile }
        stable += "\n\nYou are running on a local model on this Mac" + (privateMode ? " (Private Mode: nothing leaves the Mac)." : " because the internet is down.") +
                  " Keep replies to one or two sentences. Only call a tool when needed."
        var messages: [JSONObject] = [["role": "system", "content": stable + "\n\n" + volatile]]
        // Carry over the last few plain-text exchanges from the cloud history.
        for m in history.suffix(6) {
            guard let role = m["role"] as? String else { continue }
            if let s = m["content"] as? String { messages.append(["role": role, "content": s]); continue }
            let text = (m["content"] as? [JSONObject] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            if !text.isEmpty { messages.append(["role": role, "content": text]) }
        }
        messages.append(["role": "user", "content": userText])
        let tools = OllamaClient.tools(from: dispatcher.definitions(for: mode).filter { Self.localToolNames.contains($0["name"] as? String ?? "") })
        var guardian = LoopGuard(budget: 6)
        for round in 0..<4 {
            let reply = try await client.chat(messages: messages, tools: tools, onText: { t in turn.text += t; onText(t) })
            JarvisLog.info("Local round \(round): \(reply.text.count) chars, tools=\(reply.toolCalls.map(\.name))")
            guard !reply.toolCalls.isEmpty else { break }
            messages.append(["role": "assistant", "content": reply.text,
                             "tool_calls": reply.toolCalls.map { ["function": ["name": $0.name, "arguments": $0.arguments]] }])
            for call in reply.toolCalls {
                turn.toolCalls.append(call.name)
                let content: String
                if let loop = guardian.check(tool: call.name, input: call.arguments) { content = loop }
                else {
                    let r = await dispatcher.call(call.name, input: call.arguments, source: .user)
                    if let card = r.card { turn.cards.append(card) }
                    content = r.content
                }
                messages.append(["role": "tool", "content": content, "tool_name": call.name])
            }
        }
        if turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { turn.text = "Done."; onText("Done.") }
        // Keep the exchange in the shared history so Claude can pick it up when back online.
        history.append(["role": "user", "content": userText])
        history.append(["role": "assistant", "content": [["type": "text", "text": turn.text]]])
        trimHistory()
        return turn
    }

    /// Repairs a history so it is always valid for the Messages API, whatever happened before:
    ///  - drops empty text blocks and empty messages
    ///  - every assistant tool_use gets a tool_result in the next user message (missing ones become "interrupted")
    ///  - tool_results that don't answer the preceding assistant's tool_use are dropped
    ///  - consecutive messages from the same role are merged
    ///  - the history starts with a plain user message
    nonisolated static func sanitized(_ messages: [JSONObject]) -> [JSONObject] {
        func blocks(_ m: JSONObject) -> [JSONObject] {
            if let s = m["content"] as? String { return s.isEmpty ? [] : [["type": "text", "text": s]] }
            return (m["content"] as? [JSONObject] ?? []).compactMap { b in
                var b = b
                switch b["type"] as? String {
                case "text": return ((b["text"] as? String) ?? "").isEmpty ? nil : b
                case "tool_result":
                    if ((b["content"] as? String) ?? "").isEmpty { b["content"] = "(no output)" }
                    return b
                default: return b
                }
            }
        }
        // Server tool calls (web_search/web_fetch) and their results live in the same assistant message.
        // Drop a call without its result unless it ends the conversation (that's a pause_turn to resume),
        // and drop results whose call is gone.
        func pairServerBlocks(_ blocks: [JSONObject], isLast: Bool) -> [JSONObject] {
            let callIDs = Set(blocks.filter { $0["type"] as? String == "server_tool_use" }.compactMap { $0["id"] as? String })
            let resultIDs = Set(blocks.filter { b in
                let t = b["type"] as? String ?? ""
                return t != "tool_result" && t.hasSuffix("_tool_result")
            }.compactMap { $0["tool_use_id"] as? String })
            return blocks.filter { b in
                let t = b["type"] as? String ?? ""
                if t == "server_tool_use" { return isLast || resultIDs.contains(b["id"] as? String ?? "") }
                if t != "tool_result" && t.hasSuffix("_tool_result") { return callIDs.contains(b["tool_use_id"] as? String ?? "") }
                return true
            }
        }
        // Normalise + merge same-role runs.
        var merged: [(role: String, blocks: [JSONObject])] = []
        for m in messages {
            guard let role = m["role"] as? String, role == "user" || role == "assistant" else { continue }
            let b = blocks(m)
            guard !b.isEmpty else { continue }
            if let last = merged.last, last.role == role { merged[merged.count - 1].blocks += b } else { merged.append((role, b)) }
        }
        // Pair tool_use with tool_result.
        var out: [(role: String, blocks: [JSONObject])] = []
        var pendingIDs: [String] = []
        for var m in merged {
            if m.role == "user" {
                // Keep only results answering the previous assistant turn, in front of any text.
                let results = m.blocks.filter { $0["type"] as? String == "tool_result" && pendingIDs.contains($0["tool_use_id"] as? String ?? "") }
                let others = m.blocks.filter { $0["type"] as? String != "tool_result" }
                let answered = Set(results.compactMap { $0["tool_use_id"] as? String })
                let missing = pendingIDs.filter { !answered.contains($0) }.map { id -> JSONObject in
                    ["type": "tool_result", "tool_use_id": id, "content": "Interrupted before this finished.", "is_error": true]
                }
                m.blocks = results + missing + others
                pendingIDs = []
                if m.blocks.isEmpty { continue }
            } else {
                if !pendingIDs.isEmpty {
                    // Assistant followed assistant with unanswered tool calls: insert the results.
                    out.append(("user", pendingIDs.map { ["type": "tool_result", "tool_use_id": $0, "content": "Interrupted before this finished.", "is_error": true] }))
                    pendingIDs = []
                }
                pendingIDs = m.blocks.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["id"] as? String }
            }
            if let last = out.last, last.role == m.role { out[out.count - 1].blocks += m.blocks } else { out.append(m) }
        }
        // A trailing assistant tool_use with no answer can't be sent; drop those blocks.
        if !pendingIDs.isEmpty, var last = out.popLast() {
            last.blocks = last.blocks.filter { $0["type"] as? String != "tool_use" }
            if !last.blocks.isEmpty { out.append(last) }
        }
        // Must start with a user message that isn't only tool results.
        while let first = out.first, first.role != "user" || first.blocks.allSatisfy({ $0["type"] as? String == "tool_result" }) {
            out.removeFirst()
            if let f = out.first, f.role == "user" {
                let kept = f.blocks.filter { $0["type"] as? String != "tool_result" }
                if kept.isEmpty { continue }
                out[0].blocks = kept
            }
        }
        return out.enumerated().compactMap { i, m in
            let b = m.role == "assistant" ? pairServerBlocks(m.blocks, isLast: i == out.count - 1) : m.blocks
            return b.isEmpty ? nil : ["role": m.role, "content": b]
        }
    }

    /// Anthropic's server-side web tools. The dynamic-filtering versions need a recent model.
    nonisolated static func webTools(model: String, profile: Profile, mode: ModeDefinition, timeZone: TimeZone = .current) -> [JSONObject] {
        let web = profile.web ?? Profile.Web()
        guard web.enabled else { return [] }
        // Voice wants the basic variants: the dynamic-filtering ones (_20260209) write and run code over the
        // results, which takes several extra steps and makes Claude narrate them aloud ("let me inspect the
        // result shape"). Opt in with web.deepResearch for long, text-only research.
        let modern = web.deepResearch && ["claude-opus-5", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
                      "claude-sonnet-5", "claude-sonnet-4-6"].contains { model.hasPrefix($0) }
        var tools: [JSONObject] = []
        if ToolDispatcher.allowed("web_search", in: mode), web.maxSearchesPerTurn > 0 {
            var location: JSONObject = ["type": "approximate", "timezone": timeZone.identifier]
            // Only claim the home city when the Mac's clock says we're there (Sam travels to Singapore).
            if timeZone.identifier == profile.homeTimeZone { location["city"] = profile.world?.weatherCity ?? profile.city }
            else if timeZone.identifier == "Asia/Singapore" { location["city"] = "Singapore"; location["country"] = "SG" }
            tools.append(["type": modern ? "web_search_20260209" : "web_search_20250305", "name": "web_search",
                          "max_uses": web.maxSearchesPerTurn, "user_location": location])
        }
        if ToolDispatcher.allowed("web_fetch", in: mode), web.maxFetchesPerTurn > 0 {
            tools.append(["type": modern ? "web_fetch_20260209" : "web_fetch_20250910", "name": "web_fetch",
                          "max_uses": web.maxFetchesPerTurn, "max_content_tokens": 8000])
        }
        return tools
    }

    /// Keeps the last `max` messages without splitting a tool_use / tool_result pair.
    nonisolated static func trimmed(_ messages: [JSONObject], max: Int) -> [JSONObject] {
        guard messages.count > max else { return messages }
        return sanitized(Array(messages.suffix(max)))
    }

    nonisolated static func describe(_ messages: [JSONObject]) -> String {
        messages.map { m in
            let role = m["role"] as? String ?? "?"
            if let s = m["content"] as? String { return "\(role):str(\(s.count))" }
            let blocks = (m["content"] as? [JSONObject] ?? []).map { b -> String in
                let t = b["type"] as? String ?? "?"
                if t == "text" { return "text(\(((b["text"] as? String) ?? "").count))" }
                if t == "tool_result" { return "result(\(((b["content"] as? String) ?? "").count))" }
                return t
            }
            return "\(role):[\(blocks.joined(separator: ","))]"
        }.joined(separator: " ")
    }

    private func trimHistory() {
        // Drop oldest turns, but never split a tool_use / tool_result pair.
        while history.count > maxHistoryMessages {
            history.removeFirst()
            while let first = history.first, first["role"] as? String != "user" || (first["content"] as? [JSONObject])?.first?["type"] as? String == "tool_result" {
                history.removeFirst()
            }
        }
    }
}

/// When there is no internet, a few commands still work by pattern matching.
enum LocalFallback {
    @MainActor
    static func handle(_ text: String, dispatcher: ToolDispatcher, modes: ModeManager) async throws -> String {
        let t = text.lowercased()
        func run(_ tool: String, _ input: JSONObject) async -> String {
            let r = await dispatcher.call(tool, input: input, source: .user)
            return r.isError ? "I'm offline and that didn't work: \(r.content)" : (r.summary ?? r.content)
        }
        for mode in modes.available where t.contains("\(mode.name.lowercased()) mode") {
            return await run("set_mode", ["mode": mode.id])
        }
        if let m = t.range(of: #"volume (to )?(\d+)"#, options: .regularExpression) {
            let n = Int(t[m].filter(\.isNumber)) ?? 50
            return await run("set_volume", ["percent": n])
        }
        if t.contains("mute") { return await run("set_volume", ["mute": true]) }
        if let m = t.range(of: #"timer for (\d+) (minute|second|hour)"#, options: .regularExpression) {
            let parts = t[m].split(separator: " ")
            let n = Int(parts[2]) ?? 1
            let unit = String(parts[3])
            let secs = unit.hasPrefix("hour") ? n * 3600 : unit.hasPrefix("minute") ? n * 60 : n
            return await run("set_timer", ["seconds": secs, "label": "timer"])
        }
        if let m = t.range(of: #"open (\w[\w ]*)"#, options: .regularExpression) {
            let app = t[m].dropFirst(5).trimmingCharacters(in: .whitespaces)
            return await run("open_app", ["name": app])
        }
        if t.contains("undo") { return await run("undo_last_action", [:]) }
        if t.contains("battery") || t.contains("status") { return await run("system_status", [:]) }
        return "I'm offline right now, so I can only do local things like modes, volume, timers, and opening apps."
    }
}
