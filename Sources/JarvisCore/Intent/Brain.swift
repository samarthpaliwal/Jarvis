import Foundation
import Network

/// The agent loop: user text → Claude (streaming) → tools via the dispatcher → more Claude → reply.
/// Keeps a short conversation history that expires after a few idle minutes.
@MainActor
public final class Brain: ObservableObject {
    public typealias Turn = Reply

    /// The model and the action runner are interfaces, so the loop can be tested with scripted fakes.
    public let client: any LanguageModel
    public let dispatcher: any ActionRunner
    private let config: ConfigStore
    private let modes: ModeManager
    private let undo: UndoStack

    private var history: [JSONObject] = []
    /// Incremented per cloud turn; only the newest turn may write `history`.
    private var generation = 0
    private var lastActivity = Date.distantPast
    /// When the prompt cache was last written or read (a real request or a pre-warm).
    private var cacheTouchedAt = Date.distantPast
    private var prewarming = false
    private var historyTimeout: TimeInterval { config.tuning.llmHistoryTimeoutMinutes * 60 }
    private var maxHistoryMessages: Int { max(2, config.tuning.llmMaxHistoryMessages) }
    private var maxToolRounds: Int { max(1, config.tuning.llmMaxToolRounds) }

    @Published public private(set) var isOnline = true
    private let pathMonitor = NWPathMonitor()
    public var memory: MemoryStore?
    /// Short-term memory across the chats of one sitting (RAM only).
    public let session = SessionMemory()
    public var skills: SkillLibrary?
    public var local: OllamaClient?
    /// A second cloud brain: a model hosted by Ollama (gpt-oss:120b). Nothing runs on this Mac for it.
    public var hosted: OllamaClient?
    /// Which brain answers: "claude" (default) or "hosted". The other one steps in when the chosen one cannot answer.
    @Published public var engineChoice: String = UserDefaults.standard.string(forKey: "jarvis.brainEngine") ?? "claude" {
        didSet { UserDefaults.standard.set(engineChoice, forKey: "jarvis.brainEngine") }
    }

    public enum Engine: String, Sendable { case claude, hosted, local }

    /// Who answers this request, and who is the stand-in if that one fails.
    /// Private Mode and offline always mean the local path: a hosted model is still someone else's computer.
    nonisolated static func plan(choice: String, privateMode: Bool, online: Bool, claudeReady: Bool, hostedReady: Bool) -> (first: Engine, fallback: Engine?) {
        if privateMode || !online { return (.local, nil) }
        let wantsHosted = choice.lowercased() == "hosted"
        if wantsHosted, hostedReady { return (.hosted, claudeReady ? .claude : nil) }
        if claudeReady { return (.claude, hostedReady ? .hosted : nil) }
        if hostedReady { return (.hosted, nil) }
        return (.claude, nil)
    }
    /// Private Mode: every turn goes to the local model, nothing to the cloud.
    @Published public var privateMode: Bool = UserDefaults.standard.bool(forKey: "jarvis.privateMode") {
        didSet { UserDefaults.standard.set(privateMode, forKey: "jarvis.privateMode") }
    }
    /// Tools a small local model gets (a short list keeps it accurate).
    static let localToolNames: Set<String> = ["system_status", "open_app", "set_volume", "music", "set_timer", "set_reminder",
                                              "calendar_read", "calendar_create", "get_briefing", "set_mode", "undo_last_action",
                                              "memory", "memory_search", "contacts", "file_search", "set_brightness", "set_display_mode", "welcome_home"]

    public var model: String {
        Env.value("CLAUDE_MODEL").flatMap { $0.isEmpty ? nil : $0 } ?? config.profile.claude.model
    }

    public init(client: any LanguageModel = ClaudeClient(), dispatcher: any ActionRunner, config: ConfigStore, modes: ModeManager, undo: UndoStack) {
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
        session.closeChat()
        generation += 1
    }

    public func clearHistory() {
        history.removeAll()
        JarvisLog.info("Conversation history cleared")
    }

    /// Streams the reply text through `onText` as it arrives; returns the full turn when done.
    public func respond(to userText: String, onText: @escaping (String) -> Void) async throws -> Turn {
        let hostedReady = hosted?.hasKey ?? false
        let plan = Self.plan(choice: engineChoice, privateMode: privateMode, online: isOnline,
                             claudeReady: KeychainStore.apiKey() != nil, hostedReady: hostedReady)
        if plan.first == .hosted, let hosted {
            do { return try await respondHosted(userText, client: hosted, onText: onText) }
            catch let error where plan.fallback == .claude && !(error is CancellationError) {
                JarvisLog.warn("Hosted model failed (\(error.localizedDescription.prefix(160))); answering with Claude")
            }
        }
        do {
            return try await respondOnce(to: userText, onText: onText)
        } catch let error where plan.first == .claude && plan.fallback == .hosted && Self.shouldFallBack(from: error) {
            // Claude cannot answer right now (no key, out of budget, the service is down): the other brain does.
            guard let hosted else { throw error }
            JarvisLog.warn("Claude unavailable (\(error.localizedDescription.prefix(160))); answering with \(hosted.model)")
            return try await respondHosted(userText, client: hosted, onText: onText)
        } catch BudgetError.dailyCapReached(let spent, let cap) {
            // Out of budget for today: answer on-device if a local model is there, otherwise say so.
            guard config.profile.local?.enabled ?? true, let local, await local.status().hasModel else {
                throw BudgetError.dailyCapReached(spent: spent, cap: cap)
            }
            JarvisLog.warn(String(format: "Daily budget reached ($%.2f of $%.2f); answering with the local model", spent, cap))
            return try await respondLocally(userText, client: local, onText: onText)
        } catch ClaudeClient.ClientError.http(400, let msg) {
            // Never leave Sam stuck behind a bad history: forget it and try once more.
            JarvisLog.warn("400 from Claude (\(msg.prefix(120))); clearing conversation history and retrying once")
            history.removeAll()
            return try await respondOnce(to: userText, onText: onText)
        }
    }

    private func respondOnce(to userText: String, onText: @escaping (String) -> Void) async throws -> Turn {
        if Date().timeIntervalSince(lastActivity) > historyTimeout { history.removeAll(); session.closeChat() }
        session.keepMinutes = config.tuning.sessionMemoryMinutes
        session.maxExchanges = config.tuning.sessionMemoryExchanges
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
            // Keep only the newest picture: each one costs tokens on every later request.
            if myGeneration == generation { history = Self.keepingLatestImages(Self.sanitized(convo), count: 1) }
        }
        let mode = modes.current
        var (stable, volatile) = SystemPrompt.parts(profile: config.profile, mode: mode, online: isOnline, undoAvailable: undo.lastDescription)
        if let catalog = skills?.catalog { stable += "\n\n" + catalog }          // changes only when skills are installed
        if config.profile.memory?.enabled ?? true, let block = memory?.promptBlock() { volatile = block + "\n\n" + volatile }
        // Short-term: what was said in chats that already closed. It rides in the uncached part of the prompt.
        if let recent = session.promptBlock() { volatile = recent + "\n\n" + volatile }
        // Web tools first so the cache breakpoint stays on the last custom tool.
        let tools = Self.webTools(model: model, profile: config.profile, mode: mode, fetchMaxContentTokens: config.tuning.webFetchMaxContentTokens)
            + dispatcher.definitions(for: mode)
        var guardian = LoopGuard(budget: config.tuning.toolCallBudgetPerTurn)
        defer {
            if config.profile.memory?.archiveConversations ?? true { memory?.archive(user: userText, jarvis: turn.text, tools: turn.toolCalls) }
            if !turn.text.isEmpty { session.note(user: userText, jarvis: turn.text, tools: turn.toolCalls) }
        }

        for round in 0...maxToolRounds {
            convo = Self.sanitized(convo)
            cacheTouchedAt = Date()
            var request = ClaudeClient.Request(model: model, system: stable, messages: convo, tools: tools,
                                               maxTokens: config.profile.claude.maxTokens, effort: config.tuning.llmEffort)
            request.systemVolatile = volatile
            var assistantContent: [JSONObject] = []
            var currentText = ""
            var currentTool: (id: String, name: String, json: String)?
            var stopReason = "end_turn"
            var blockTypes: [String] = []
            var needsGap = false   // text resuming after a web search needs a space ("Checking now. The…")

            let roundStarted = Date()
            var roundUsage = (0, 0, 0, 0)
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
                    // The API reports usage at the start of a message and again, cumulatively, at the end.
                    // Keep the largest value seen per field and add it once per round. Adding both events
                    // counted every token twice.
                    roundUsage = (max(roundUsage.0, i), max(roundUsage.1, o), max(roundUsage.2, cr), max(roundUsage.3, cw))
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
            // Before any return below: a returned `turn` is copied before a defer would run.
            turn.inputTokens += roundUsage.0; turn.outputTokens += roundUsage.1
            turn.cacheReadTokens += roundUsage.2; turn.cacheWriteTokens += roundUsage.3
            RequestTrace.current?.event(.intent, "llm_round", ["round": round, "stop": stopReason, "model": model,
                                                               "ms": (Date().timeIntervalSince(roundStarted) * 1000).rounded(),
                                                               "tool_calls": assistantContent.filter { ($0["type"] as? String)?.hasSuffix("tool_use") ?? false }.count])
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
                results.append(Self.toolResultBlock(id: use["id"] as? String ?? "", result))
            }
            convo.append(["role": "user", "content": results])
            if Task.isCancelled { return turn }   // results are recorded, so the history stays valid
        }
        return turn
    }

    // MARK: Pictures in tool results

    /// A tool result for the API: plain text, or text plus pictures when the tool attached any.
    nonisolated static func toolResultBlock(id: String, _ result: ToolResult) -> JSONObject {
        guard !result.images.isEmpty else {
            return ["type": "tool_result", "tool_use_id": id, "content": result.content, "is_error": result.isError]
        }
        var content: [JSONObject] = [["type": "text", "text": result.content]]
        for image in result.images {
            content.append(["type": "image", "source": ["type": "base64", "media_type": image.mediaType, "data": image.data.base64EncodedString()]])
        }
        return ["type": "tool_result", "tool_use_id": id, "content": content, "is_error": result.isError]
    }

    nonisolated static let imageGone = "[An earlier picture was here. It is no longer available; use look again if you need to see.]"

    /// Replaces all but the newest `count` pictures in the history with a short note.
    nonisolated static func keepingLatestImages(_ messages: [JSONObject], count: Int) -> [JSONObject] {
        var remaining = count
        var out = messages
        for i in out.indices.reversed() {
            guard var blocks = out[i]["content"] as? [JSONObject] else { continue }
            var changed = false
            for j in blocks.indices.reversed() {
                guard blocks[j]["type"] as? String == "tool_result", var inner = blocks[j]["content"] as? [JSONObject] else { continue }
                for k in inner.indices.reversed() where inner[k]["type"] as? String == "image" {
                    if remaining > 0 { remaining -= 1 } else { inner[k] = ["type": "text", "text": imageGone]; changed = true }
                }
                blocks[j]["content"] = inner
            }
            if changed { out[i]["content"] = blocks }
        }
        return out
    }

    // MARK: Cache pre-warm

    /// Called when a spoken request starts. If the prompt cache has probably expired (5-minute lifetime),
    /// warm it now, while the user is still talking, so the real request reads ~20k tokens from cache
    /// instead of writing them. A cold first token was 4.9 s at the 90th percentile against 2.3 s warm.
    /// Costs one cache read when the cache was still warm; the write would have been paid by the turn anyway.
    public func prewarmIfCold(force: Bool = false) {
        let after = config.tuning.cachePrewarmAfterSeconds
        guard !prewarming, isOnline, !privateMode else { return }
        guard force || (after > 0 && Date().timeIntervalSince(cacheTouchedAt) > after) else { return }
        prewarming = true
        cacheTouchedAt = Date()
        let mode = modes.current
        var (stable, _) = SystemPrompt.parts(profile: config.profile, mode: mode, online: isOnline, undoAvailable: undo.lastDescription)
        if let catalog = skills?.catalog { stable += "\n\n" + catalog }
        let tools = Self.webTools(model: model, profile: config.profile, mode: mode, fetchMaxContentTokens: config.tuning.webFetchMaxContentTokens)
            + dispatcher.definitions(for: mode)
        let request = ClaudeClient.Request(model: model, system: stable, messages: [], tools: tools,
                                           maxTokens: 0, effort: config.tuning.llmEffort)
        let client = client
        let trace = RequestTrace.current
        let started = Date()
        Task { [weak self] in
            do {
                let usage = try await client.prewarm(request)
                let ms = (Date().timeIntervalSince(started) * 1000).rounded()
                JarvisLog.info("Cache pre-warm: read \(usage.cacheRead), wrote \(usage.cacheWrite) tokens in \(Int(ms)) ms", request: trace?.id)
                trace?.event(.intent, "cache_prewarm", ["ms": ms, "cache_read": usage.cacheRead, "cache_write": usage.cacheWrite])
            } catch {
                JarvisLog.warn("Cache pre-warm failed: \(error.localizedDescription)", request: trace?.id)
            }
            await MainActor.run { self?.prewarming = false }
        }
    }

    // MARK: Local model (Ollama)

    /// Errors after which the other brain should try: Claude is not reachable or not allowed to answer.
    /// A refusal, a cancelled turn, or a request Claude rejected as malformed is not one of them.
    nonisolated static func shouldFallBack(from error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is BudgetError { return true }
        if let e = error as? ClaudeClient.ClientError {
            switch e {
            case .noAPIKey: return true
            case .http(let code, _): return code == 401 || code == 403 || code == 429 || code >= 500
            default: return true
            }
        }
        return error is URLError || error is TimeoutError
    }

    /// A turn answered by the hosted model: the same tools and safety checks as Claude, minus what only
    /// Claude has (web search on Anthropic's side, and eyes: it cannot look at pictures).
    func respondHosted(_ userText: String, client: OllamaClient, onText: @escaping (String) -> Void) async throws -> Turn {
        var turn = try await respondLocally(userText, client: client, onText: onText, hosted: true)
        turn.engine = "hosted"
        turn.inputTokens = client.lastUsage.input
        turn.outputTokens = client.lastUsage.output
        if config.profile.memory?.archiveConversations ?? true { memory?.archive(user: userText, jarvis: turn.text, tools: turn.toolCalls) }
        if !turn.text.isEmpty { session.note(user: userText, jarvis: turn.text, tools: turn.toolCalls) }
        return turn
    }

    /// Tools the hosted model does not get: they return pictures, which it cannot see.
    static let hostedExcludedTools: Set<String> = ["look"]

    func respondLocally(_ userText: String, client: OllamaClient, onText: @escaping (String) -> Void, hosted: Bool = false) async throws -> Turn {
        var turn = Turn()
        turn.engine = "local"
        let mode = modes.current
        var (stable, volatile) = SystemPrompt.parts(profile: config.profile, mode: mode, online: isOnline, undoAvailable: undo.lastDescription)
        if let block = memory?.promptBlock() { volatile = block + "\n\n" + volatile }
        if hosted {
            stable += "\n\nYou have no web search and cannot see images in this session. If a request needs either, say so in one sentence."
        } else {
            stable += "\n\nYou are running on a local model on this Mac" + (privateMode ? " (Private Mode: nothing leaves the Mac)." : " because the internet is down.") +
                      " Keep replies to one or two sentences. Only call a tool when needed."
        }
        var messages: [JSONObject] = [["role": "system", "content": stable + "\n\n" + volatile]]
        // Carry over the last few plain-text exchanges from the cloud history.
        for m in history.suffix(6) {
            guard let role = m["role"] as? String else { continue }
            if let s = m["content"] as? String { messages.append(["role": role, "content": s]); continue }
            let text = (m["content"] as? [JSONObject] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            if !text.isEmpty { messages.append(["role": role, "content": text]) }
        }
        messages.append(["role": "user", "content": userText])
        let tools = OllamaClient.tools(from: dispatcher.definitions(for: mode).filter {
            let name = $0["name"] as? String ?? ""
            return hosted ? !Self.hostedExcludedTools.contains(name) : Self.localToolNames.contains(name)
        })
        var guardian = LoopGuard(budget: hosted ? config.tuning.toolCallBudgetPerTurn : config.tuning.localToolCallBudgetPerTurn)
        for round in 0..<(hosted ? maxToolRounds : 4) {
            let reply = try await client.chat(messages: messages, tools: tools, onText: { t in turn.text += t; onText(t) })
            JarvisLog.info("\(hosted ? "Hosted (\(client.model))" : "Local") round \(round): \(reply.text.count) chars, tools=\(reply.toolCalls.map(\.name))")
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
                    // Content is a string, or a list of blocks when a picture is attached. Only an empty one is replaced.
                    if let list = b["content"] as? [JSONObject] { if list.isEmpty { b["content"] = "(no output)" } }
                    else if ((b["content"] as? String) ?? "").isEmpty { b["content"] = "(no output)" }
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
    nonisolated static func webTools(model: String, profile: Profile, mode: ModeDefinition, timeZone: TimeZone = .current,
                                     fetchMaxContentTokens: Int = Tuning().webFetchMaxContentTokens) -> [JSONObject] {
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
                          "max_uses": web.maxFetchesPerTurn, "max_content_tokens": fetchMaxContentTokens])
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
    static func handle(_ text: String, dispatcher: any ActionRunner, modes: ModeManager) async throws -> String {
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
