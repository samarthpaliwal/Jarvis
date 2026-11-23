import Foundation

/// "Ask me once per chat." After Sam says yes to one kind of action, the same kind does not ask again
/// while the chat is alive: until he has not asked for anything for two minutes. Off unless switched on.
///
/// Always true:
/// - a yes to one kind of action is not a yes to another (sending an email is not running a shell command),
/// - a yes given at the Mac does not cover the phone, and the other way round, so the first yes from the
///   phone in a chat still goes through its voice check.
///
/// Two further limits are on by default and can each be switched off in the menu:
/// - `coversOutsideContent` false: a request that read an email, a web page, a file, or the screen always
///   asks for the specific action. That is where an injected instruction would come from.
/// - `coversPhone` false: anything asked from the phone always asks.
public struct ApprovalSession: Equatable, Sendable {
    public static let key = "jarvis.approveOncePerChat"
    public static let outsideKey = "jarvis.approveOnce.outsideContent"
    public static let phoneKey = "jarvis.approveOnce.phone"
    public var enabled: Bool
    public var coversOutsideContent: Bool
    public var coversPhone: Bool
    public var idleSeconds: TimeInterval = 120
    private var granted: Set<String> = []
    private var lastActivity: Date?

    public init(enabled: Bool = false, coversOutsideContent: Bool = false, coversPhone: Bool = false) {
        self.enabled = enabled; self.coversOutsideContent = coversOutsideContent; self.coversPhone = coversPhone
    }

    public static func saved(_ defaults: UserDefaults = .standard) -> ApprovalSession {
        ApprovalSession(enabled: defaults.bool(forKey: key), coversOutsideContent: defaults.bool(forKey: outsideKey), coversPhone: defaults.bool(forKey: phoneKey))
    }

    private static func slot(_ tool: String, fromPhone: Bool) -> String { (fromPhone ? "phone|" : "mac|") + tool }

    private func alive(at now: Date) -> Bool {
        guard let last = lastActivity else { return false }
        return now.timeIntervalSince(last) <= idleSeconds
    }

    /// Sam asked for something. A gap longer than the idle time ends the chat and every yes with it.
    public mutating func userActed(at now: Date) {
        if !alive(at: now) { granted = [] }
        lastActivity = now
    }

    public mutating func grant(_ tool: String, at now: Date, fromPhone: Bool = false) {
        guard enabled else { return }
        granted.insert(Self.slot(tool, fromPhone: fromPhone))
        lastActivity = now
    }

    public func covers(_ tool: String, at now: Date, readOutsideContent: Bool, fromPhone: Bool) -> Bool {
        guard enabled, alive(at: now), granted.contains(Self.slot(tool, fromPhone: fromPhone)) else { return false }
        if readOutsideContent, !coversOutsideContent { return false }
        if fromPhone, !coversPhone { return false }
        return true
    }

    public mutating func end() { granted = []; lastActivity = nil }
}
