import Foundation

/// The four permission tiers. Enforced by `ToolDispatcher`, not by the prompt.
public enum Tier: Int, Codable, Comparable, CustomStringConvertible, Sendable {
    /// Read-only. Runs automatically.
    case auto = 0
    /// Reversible, low risk. Runs automatically, always logged, undoable where possible.
    case free = 1
    /// Risky or irreversible. Jarvis previews the exact action and waits for an explicit yes.
    case approve = 2
    /// Never, even when asked.
    case never = 3

    public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        switch self {
        case .auto: return "Tier 0 · automatic"
        case .free: return "Tier 1 · free"
        case .approve: return "Tier 2 · approval"
        case .never: return "Tier 3 · never"
        }
    }
}

/// Who asked for the tool call. Only the user (via Claude in a live turn) can trigger Tier 2.
public enum ToolCallSource: String, Codable, Sendable {
    case user       // Claude acting on what Sam just said
    case proactive  // briefings, nudges, timers
    case mode       // automatic mode-change setup
}
