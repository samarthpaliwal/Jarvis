import Foundation

/// "Ask me once per chat." After Sam says yes to one kind of action, the same kind does not ask again
/// while the chat is alive: until he has not asked for anything for two minutes. Off unless switched on.
///
/// What it never covers, so those always ask for the specific action:
/// - a request that read an email, a web page, a file, or the screen (that is where an injected instruction
///   would come from),
/// - anything asked from the phone,
/// - a different kind of action (a yes to sending an email is not a yes to running a shell command).
public struct ApprovalSession: Equatable, Sendable {
    public static let key = "jarvis.approveOncePerChat"
    public var enabled: Bool
    public var idleSeconds: TimeInterval = 120
    private var granted: Set<String> = []
    private var lastActivity: Date?

    public init(enabled: Bool = false) { self.enabled = enabled }

    private func alive(at now: Date) -> Bool {
        guard let last = lastActivity else { return false }
        return now.timeIntervalSince(last) <= idleSeconds
    }

    /// Sam asked for something. A gap longer than the idle time ends the chat and every yes with it.
    public mutating func userActed(at now: Date) {
        if !alive(at: now) { granted = [] }
        lastActivity = now
    }

    public mutating func grant(_ tool: String, at now: Date) {
        guard enabled else { return }
        granted.insert(tool)
        lastActivity = now
    }

    public func covers(_ tool: String, at now: Date, readOutsideContent: Bool, fromPhone: Bool) -> Bool {
        enabled && !readOutsideContent && !fromPhone && alive(at: now) && granted.contains(tool)
    }

    public mutating func end() { granted = []; lastActivity = nil }
}
