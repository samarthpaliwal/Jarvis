import Foundation

/// Approval request shown in the notch and spoken aloud.
public struct ApprovalRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let toolName: String
    public let preview: String
    public init(id: UUID = UUID(), toolName: String, preview: String) {
        self.id = id; self.toolName = toolName; self.preview = preview
    }
}

public enum DispatchError: LocalizedError, Equatable {
    case unknownTool(String)
    case tierNever(String)
    case denied(String)
    case needsApproval(String)
    case rejected(String)
    case notAllowedInMode(String, String)
    case proactiveCannotApprove(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let n): return "Unknown tool '\(n)'."
        case .tierNever(let n): return "'\(n)' is never allowed."
        case .denied(let why): return "Refused by the denylist: \(why)"
        case .needsApproval(let n): return "'\(n)' needs approval."
        case .rejected(let n): return "Sam did not approve '\(n)'."
        case .notAllowedInMode(let n, let m): return "'\(n)' is not allowed in \(m) mode."
        case .proactiveCannotApprove(let n): return "'\(n)' needs approval and cannot be triggered automatically."
        }
    }
}

/// The one place every tool call passes through. Order of checks:
///   1. tool exists      2. Tier 3 → refuse     3. denylist on declared targets
///   4. mode allow-list  5. Tier 2 → explicit approval (user-sourced calls only)
///   6. run, log, surface a one-line summary.
@MainActor
public final class ToolDispatcher {
    public private(set) var tools: [String: JarvisTool] = [:]
    public var approvalHandler: ((ApprovalRequest) async -> Bool)?
    /// "Ask once per chat" (menu toggle). See ApprovalSession for what it never covers.
    public var approvalSession = ApprovalSession.saved()
    /// The owner lock: a sentence saying why this tool may not run right now, or nil to go ahead.
    /// Arguments: the tool's name, and whether the request came from the paired phone.
    public var ownerGate: ((String, Bool) async -> String?)?
    private var askedFromPhone: Bool { RequestTrace.current?.source == "remote" }
    var now: () -> Date = Date.init

    /// True when an earlier yes in this chat already covers this kind of action.
    private func coveredByEarlierYes(_ name: String) -> Bool {
        approvalSession.covers(name, at: now(), readOutsideContent: !(RequestTrace.current?.untrustedSources ?? []).isEmpty,
                               fromPhone: RequestTrace.current?.source == "remote")
    }
    /// Called after Tier 1+ actions with the one-liner ("Set volume to 40%").
    public var onSummary: ((String) -> Void)?
    /// Seconds one tool may run. Read from Tuning on every call.
    public var toolTimeout: Double { config.tuning.toolTimeoutSeconds }

    private let config: ConfigStore
    private let log: ActionLog
    public let context: ToolContext

    public init(config: ConfigStore, context: ToolContext, log: ActionLog) {
        self.config = config
        self.context = context
        self.log = log
    }

    /// Server-side tools (web_search, web_fetch) run on Anthropic's side, never through `call`, but are
    /// still logged like every other tool call.
    public func recordServerTool(_ name: String, input: JSONObject) {
        log.record(ActionRecord(timestamp: Date(), tool: name, tier: Tier.auto.rawValue, source: "claude-server",
                                input: Self.describe(input), outcome: "ran", summary: nil, durationMs: nil))
        RequestTrace.current?.tool(name, ms: nil, outcome: "ran", tier: Tier.auto.rawValue)
        if name.hasPrefix("web_") { RequestTrace.current?.markUntrusted("a web page") }
    }

    /// What kind of outside content a tool reads, in words for the approval prompt.
    nonisolated static func kind(of tool: String) -> String {
        if tool.hasPrefix("email") { return "an email" }
        if tool.hasPrefix("calendar") { return "the calendar" }
        if tool.hasPrefix("file") { return "a file" }
        if tool.hasPrefix("notion") { return "Notion" }
        return "outside content"
    }

    /// Prompt-injection defence at the last step: if this request read outside content before asking for
    /// something irreversible, the approval says so, in the same breath as the action itself.
    static func withOutsideContentNote(_ preview: String) -> String {
        let sources = RequestTrace.current?.untrustedSources ?? []
        guard !sources.isEmpty else { return preview }
        return preview + ". Note: I read \(sources.joined(separator: " and ")) before asking this"
    }

    typealias Confirmer = @MainActor @Sendable (String) async -> Bool
    @TaskLocal static var confirmer: Confirmer?

    /// For tools: ask the user to approve one specific thing before doing it. False when the user says no,
    /// does not answer, or the call did not come from a live user turn. Outside a tool call it is always false.
    public static func confirm(_ preview: String) async -> Bool {
        guard let confirmer else { return false }
        return await confirmer(preview)
    }

    public func register(_ tool: JarvisTool) { tools[tool.name] = tool }
    public func register(_ list: [JarvisTool]) { list.forEach(register) }

    /// Definitions for Claude, filtered by the current mode's allow-list.
    public func definitions(for mode: ModeDefinition) -> [JSONObject] {
        tools.values
            .filter { $0.tier != .never && Self.allowed($0.name, in: mode) }
            .sorted { $0.name < $1.name }
            .map(\.definition)
    }

    public var guardian: DenylistGuard {
        DenylistGuard(denylist: config.denylist, allowedFolders: config.allowedFolders)
    }

    nonisolated static func allowed(_ name: String, in mode: ModeDefinition) -> Bool {
        mode.allowedTools.contains("*") || mode.allowedTools.contains(name)
    }

    public func call(_ name: String, input: JSONObject, source: ToolCallSource) async -> ToolResult {
        let started = Date()
        if source == .user { approvalSession.userActed(at: now()) }
        let inputSummary = Self.describe(input)
        func record(_ outcome: String, tier: Tier, summary: String? = nil) {
            let ms = Date().timeIntervalSince(started) * 1000
            log.record(ActionRecord(timestamp: started, tool: name, tier: tier.rawValue, source: source.rawValue,
                                    input: inputSummary, outcome: outcome, summary: summary,
                                    durationMs: Int(ms)))
            // "approved" is a step on the way to running, not the end of the call.
            if outcome != "approved" { RequestTrace.current?.tool(name, ms: ms, outcome: outcome, tier: tier.rawValue) }
        }

        guard let tool = tools[name] else {
            record("unknown", tier: .never)
            return .error(DispatchError.unknownTool(name).localizedDescription)
        }
        if tool.tier == .never {
            record("refused", tier: .never)
            return .error(DispatchError.tierNever(name).localizedDescription)
        }
        do {
            try guardian.check(tool.targets(for: input))
        } catch {
            record("refused", tier: tool.tier, summary: "\(error)")
            JarvisLog.warn("Denylist refused \(name): \(error)")
            return .error(DispatchError.denied("\(error)").localizedDescription)
        }
        if tool.userOnly, source != .user {
            record("refused", tier: tool.tier, summary: "user-only tool from \(source.rawValue)")
            return .error("\(name) only runs when Sam asks for it directly.")
        }
        // Personal tools need the owner at the Mac. Checked before any approval is asked for.
        if let why = await ownerGate?(name, askedFromPhone) {
            record("locked", tier: tool.tier, summary: String(why.prefix(120)))
            return .error(why)
        }
        let mode = context.modes.current
        guard Self.allowed(name, in: mode) else {
            record("denied", tier: tool.tier, summary: "mode \(mode.id)")
            return .error(DispatchError.notAllowedInMode(name, mode.name).localizedDescription)
        }
        if tool.tier == .approve {
            guard source == .user else {
                record("refused", tier: .approve, summary: "non-user source \(source.rawValue)")
                return .error(DispatchError.proactiveCannotApprove(name).localizedDescription)
            }
            // Never ask for a yes to something that cannot happen.
            if let why = await tool.refusal(for: input, context: context) {
                record("refused", tier: .approve, summary: why)
                return .error(why)
            }
            let request = ApprovalRequest(toolName: name, preview: Self.withOutsideContentNote(await tool.approvalPreview(for: input, context: context)))
            if coveredByEarlierYes(name) {
                record("approved", tier: .approve, summary: "earlier yes this chat: \(request.preview)")
                JarvisLog.info("Approval: covered by an earlier yes this chat (\(name))")
            } else {
            guard let handler = approvalHandler else {
                record("denied", tier: .approve, summary: "no approval handler")
                return .error(DispatchError.needsApproval(name).localizedDescription)
            }
            let ok = await handler(request)
            guard ok else {
                record("rejected", tier: .approve, summary: request.preview)
                return .error(DispatchError.rejected(name).localizedDescription)
            }
            record("approved", tier: .approve, summary: request.preview)
            approvalSession.grant(name, at: now(), fromPhone: askedFromPhone)
            }
        }
        do {
            // A tool that hangs (one Gmail call once ran for 15 minutes) must not hang the request.
            let context = context
            // A tool may need a yes for one particular case (moving an event other people are invited to).
            // It asks through ToolDispatcher.confirm, which reaches the same approval card and voice prompt,
            // and only for calls that come from a live user turn.
            let ask: Confirmer = { [weak self] preview in
                guard let self, source == .user, let handler = self.approvalHandler else {
                    record("refused", tier: .approve, summary: "confirmation not available: \(preview)")
                    return false
                }
                if self.coveredByEarlierYes(name) {
                    record("approved", tier: .approve, summary: "earlier yes this chat: \(preview)")
                    return true
                }
                let ok = await handler(ApprovalRequest(toolName: name, preview: Self.withOutsideContentNote(preview)))
                record(ok ? "approved" : "rejected", tier: .approve, summary: preview)
                if ok { self.approvalSession.grant(name, at: self.now(), fromPhone: self.askedFromPhone) }
                return ok
            }
            var result = try await Self.$confirmer.withValue(ask) {
                try await withDeadline("\(name)", seconds: toolTimeout) { @MainActor in
                    try await tool.run(input: input, context: context)
                }
            }
            if result.content.contains("<untrusted_content") { RequestTrace.current?.markUntrusted(Self.kind(of: name)) }
            let redacted = SecretRedactor.redact(result.content)
            if !redacted.kinds.isEmpty {
                result.content = redacted.text
                JarvisLog.warn("Redacted \(redacted.kinds.joined(separator: ", ")) from \(name) output")
            }
            record(result.isError ? "failed" : "ran", tier: tool.tier,
                   summary: [result.summary, redacted.kinds.isEmpty ? nil : "redacted: \(redacted.kinds.joined(separator: ","))"].compactMap { $0 }.joined(separator: " · "))
            if tool.tier >= .free, let s = result.summary, !result.isError { onSummary?(s) }
            return result
        } catch let timeout as TimeoutError {
            record("timeout", tier: tool.tier, summary: timeout.localizedDescription)
            JarvisLog.error("Tool \(name) timed out after \(Int(timeout.seconds)) s")
            return .error("\(name) did not finish within \(Int(timeout.seconds)) seconds and was stopped. Tell the user it timed out.")
        } catch {
            record("failed", tier: tool.tier, summary: error.localizedDescription)
            return .error(error.localizedDescription)
        }
    }

    static func describe(_ input: JSONObject) -> String {
        let s = input.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        return s.count > 300 ? String(s.prefix(300)) + "…" : s
    }
}
