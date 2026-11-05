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
    }

    public let client: ClaudeClient
    public let dispatcher: ToolDispatcher
    private let config: ConfigStore
    private let modes: ModeManager
    private let undo: UndoStack

    private var history: [JSONObject] = []
    private var lastActivity = Date.distantPast
    private let historyTimeout: TimeInterval = 10 * 60
    private let maxHistoryMessages = 24
    private let maxToolRounds = 6

    @Published public private(set) var isOnline = true
    private let pathMonitor = NWPathMonitor()

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

    public func clearHistory() {
        history.removeAll()
        JarvisLog.info("Conversation history cleared")
    }

    /// Streams the reply text through `onText` as it arrives; returns the full turn when done.
    public func respond(to userText: String, onText: @escaping (String) -> Void) async throws -> Turn {
        if Date().timeIntervalSince(lastActivity) > historyTimeout { history.removeAll() }
        lastActivity = Date()
        var turn = Turn()

        guard isOnline else {
            turn.text = try await LocalFallback.handle(userText, dispatcher: dispatcher, modes: modes)
            onText(turn.text)
            return turn
        }

        history.append(["role": "user", "content": userText])
        trimHistory()
        let mode = modes.current
        let (stable, volatile) = SystemPrompt.parts(profile: config.profile, mode: mode, online: isOnline, undoAvailable: undo.lastDescription)
        let tools = dispatcher.definitions(for: mode)

        for round in 0...maxToolRounds {
            history = Self.sanitized(history)
            var request = ClaudeClient.Request(model: model, system: stable, messages: history, tools: tools,
                                               maxTokens: config.profile.claude.maxTokens, effort: "low")
            request.systemVolatile = volatile
            var assistantContent: [JSONObject] = []
            var currentText = ""
            var currentTool: (id: String, name: String, json: String)?
            var stopReason = "end_turn"
            var blockTypes: [String] = []

            let events = client.stream(request)
            do {
            for try await event in events {
                switch event {
                case .blockStart(let type):
                    blockTypes.append(type)
                case .textDelta(let t):
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
                }
            }
            } catch let e as ClaudeClient.ClientError {
                if case .http(400, _) = e { JarvisLog.error("400 request shape: \(Self.describe(history))") }
                throw e
            }
            if !currentText.isEmpty { assistantContent.append(["type": "text", "text": currentText]) }
            JarvisLog.info("Claude round \(round): stop=\(stopReason) blocks=\(blockTypes) text=\(currentText.count + assistantContent.compactMap { ($0["text"] as? String)?.count }.reduce(0, +)) chars")
            if assistantContent.isEmpty {
                // Empty reply (cut off, refused, or nothing to say): don't poison the history with an empty block.
                JarvisLog.warn("Claude returned no content (stop: \(stopReason)); dropping this exchange from history")
                history.removeLast() // the user message we just added, or the tool results
                if turn.text.isEmpty && !turn.refused { turn.text = "Sorry, I lost that one. Say it again?"; onText(turn.text) }
                return turn
            }
            history.append(["role": "assistant", "content": assistantContent])

            let toolUses = assistantContent.filter { $0["type"] as? String == "tool_use" }
            if turn.refused {
                let msg = "I can't help with that one."
                if turn.text.isEmpty { turn.text = msg; onText(msg) }
                return turn
            }
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
                let result = await dispatcher.call(name, input: input, source: .user)
                if let card = result.card { turn.cards.append(card) }
                results.append(["type": "tool_result", "tool_use_id": use["id"] as? String ?? "",
                                "content": result.content, "is_error": result.isError])
            }
            history.append(["role": "user", "content": results])
        }
        return turn
    }

    /// Drops empty text blocks and content-less messages so a bad turn can never break the next one.
    static func sanitized(_ messages: [JSONObject]) -> [JSONObject] {
        messages.compactMap { m in
            var m = m
            if let s = m["content"] as? String { return s.isEmpty ? nil : m }
            guard let blocks = m["content"] as? [JSONObject] else { return nil }
            let kept = blocks.filter { b in
                if b["type"] as? String == "text" { return !((b["text"] as? String) ?? "").isEmpty }
                if b["type"] as? String == "tool_result" {
                    return true
                }
                return true
            }.map { b -> JSONObject in
                var b = b
                if b["type"] as? String == "tool_result", ((b["content"] as? String) ?? "").isEmpty { b["content"] = "(no output)" }
                return b
            }
            if kept.isEmpty { return nil }
            m["content"] = kept
            return m
        }
    }

    static func describe(_ messages: [JSONObject]) -> String {
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
