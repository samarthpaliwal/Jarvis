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
    /// Called after Tier 1+ actions with the one-liner ("Set volume to 40%").
    public var onSummary: ((String) -> Void)?

    private let config: ConfigStore
    private let log: ActionLog
    public let context: ToolContext

    public init(config: ConfigStore, context: ToolContext, log: ActionLog) {
        self.config = config
        self.context = context
        self.log = log
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

    static func allowed(_ name: String, in mode: ModeDefinition) -> Bool {
        mode.allowedTools.contains("*") || mode.allowedTools.contains(name)
    }

    public func call(_ name: String, input: JSONObject, source: ToolCallSource) async -> ToolResult {
        let started = Date()
        let inputSummary = Self.describe(input)
        func record(_ outcome: String, tier: Tier, summary: String? = nil) {
            log.record(ActionRecord(timestamp: started, tool: name, tier: tier.rawValue, source: source.rawValue,
                                    input: inputSummary, outcome: outcome, summary: summary,
                                    durationMs: Int(Date().timeIntervalSince(started) * 1000)))
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
            let request = ApprovalRequest(toolName: name, preview: tool.preview(for: input))
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
        }
        do {
            let result = try await tool.run(input: input, context: context)
            record(result.isError ? "failed" : "ran", tier: tool.tier, summary: result.summary)
            if tool.tier >= .free, let s = result.summary, !result.isError { onSummary?(s) }
            return result
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
