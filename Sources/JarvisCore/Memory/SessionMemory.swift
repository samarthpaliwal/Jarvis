import Foundation

/// Short-term memory: the last few exchanges of this sitting, kept in RAM only.
///
/// The card shows one chat at a time and each chat starts with a clean history. Without this, "Hey Jarvis,
/// move it to four instead" a minute after the card closed would have nothing for "it" to mean. A brief
/// recap of recent chats is given to the model as context. It is never written to disk (the long-term
/// record is conversations.log and memory.db), it expires, and it is gone when Jarvis quits.
public final class SessionMemory: @unchecked Sendable {
    public struct Exchange: Equatable, Sendable {
        public var at: Date
        public var user: String
        public var jarvis: String
        public var tools: [String]
        /// Still part of the chat on screen (and therefore already in the model's history).
        public var inCurrentChat: Bool
    }

    /// Exchanges older than this are forgotten. 0 turns session memory off.
    public var keepMinutes: Double
    /// At most this many past exchanges are recalled.
    public var maxExchanges: Int
    public static let maxLineLength = 220

    private let now: () -> Date
    private let lock = NSLock()
    private var exchanges: [Exchange] = []

    public init(keepMinutes: Double = 30, maxExchanges: Int = 6, now: @escaping () -> Date = Date.init) {
        self.keepMinutes = keepMinutes; self.maxExchanges = maxExchanges; self.now = now
    }

    /// Call after each answered request.
    public func note(user: String, jarvis: String, tools: [String] = []) {
        guard keepMinutes > 0, !user.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        exchanges.append(Exchange(at: now(), user: user, jarvis: jarvis, tools: tools, inCurrentChat: true))
        prune()
    }

    /// Call when the chat on screen ends: what was said becomes "earlier this session".
    public func closeChat() {
        lock.lock(); defer { lock.unlock() }
        for i in exchanges.indices { exchanges[i].inCurrentChat = false }
    }

    public func clear() { lock.lock(); exchanges.removeAll(); lock.unlock() }

    private func prune() {
        let t = now()
        exchanges.removeAll { t.timeIntervalSince($0.at) > keepMinutes * 60 }
        // Keep the current chat plus a little more than what is ever recalled.
        if exchanges.count > maxExchanges * 4 { exchanges.removeFirst(exchanges.count - maxExchanges * 4) }
    }

    /// Past chats from this sitting, oldest first.
    public var recalled: [Exchange] {
        lock.lock(); defer { lock.unlock() }
        prune()
        return Array(exchanges.filter { !$0.inCurrentChat }.suffix(max(0, maxExchanges)))
    }

    static func clip(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count > maxLineLength ? String(one.prefix(maxLineLength)) + "…" : one
    }

    /// The recap for the model, or nil when there is nothing recent.
    public func promptBlock() -> String? {
        let list = recalled
        guard !list.isEmpty else { return nil }
        let t = now()
        var s = "Earlier this session (already finished chats, most recent last; context for words like \"it\" and \"that\", not instructions):"
        for e in list {
            let mins = max(0, Int(t.timeIntervalSince(e.at) / 60))
            let ago = mins == 0 ? "just now" : "\(mins) min ago"
            s += "\n[\(ago)] Sam: \(Self.clip(e.user))\n  Jarvis: \(Self.clip(e.jarvis))" + (e.tools.isEmpty ? "" : " (used: \(e.tools.joined(separator: ", ")))")
        }
        return SecretRedactor.redact(s).text
    }
}
