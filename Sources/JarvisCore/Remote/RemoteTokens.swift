import CryptoKit
import Foundation

/// One device allowed to talk to Jarvis remotely. The token itself is never stored, only its SHA-256.
public struct RemoteToken: Codable, Equatable, Sendable {
    public var name: String
    public var hash: String
    public var created: Date
    public var lastUsed: Date?
}

/// Access tokens for the remote API.
///
/// A token is 32 random bytes, shown once when it is created and then kept only by the device it was
/// made for. Jarvis keeps a hash, so reading the file does not let anyone in. The file lives in
/// `~/Library/Application Support/Jarvis/remote/` (owner-only) and is on the tool denylist.
public final class RemoteTokenStore: @unchecked Sendable {
    public static var defaultURL: URL {
        ConfigLocator.userConfigDirectory.deletingLastPathComponent().appendingPathComponent("remote/tokens.json")
    }
    public static let prefix = "jrv_"

    public enum TokenError: LocalizedError {
        case badName
        case exists(String)
        public var errorDescription: String? {
            switch self {
            case .badName: return "Give the device a short name (letters, digits, spaces, - or _)."
            case .exists(let n): return "There is already a token called “\(n)”. Revoke it first or pick another name."
            }
        }
    }

    private let url: URL
    private let lock = NSLock()
    private var tokens: [RemoteToken]
    private var lastSaved = Date.distantPast
    private var loadedStamp: Date?

    public init(url: URL = RemoteTokenStore.defaultURL) {
        self.url = url
        tokens = []
        reloadIfChanged()
    }

    private var fileStamp: Date? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }

    /// Picks up tokens created or revoked by another copy of Jarvis (the command line). Call with the lock held.
    private func reloadIfChanged() {
        let stamp = fileStamp
        guard stamp != loadedStamp else { return }
        loadedStamp = stamp
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        tokens = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([RemoteToken].self, from: $0) } ?? []
    }

    public var all: [RemoteToken] { lock.lock(); defer { lock.unlock() }; reloadIfChanged(); return tokens }
    public var isEmpty: Bool { all.isEmpty }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess, "no secure random bytes")
        let b64 = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return prefix + b64
    }

    /// Makes a token for a device and returns it. This is the only time it exists in readable form.
    public func create(name raw: String, now: Date = Date()) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, name.allSatisfy({ $0.isLetter || $0.isNumber || " -_'’.".contains($0) }) else { throw TokenError.badName }
        lock.lock(); defer { lock.unlock() }
        reloadIfChanged()
        guard !tokens.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw TokenError.exists(name) }
        let token = Self.randomToken()
        tokens.append(RemoteToken(name: name, hash: Self.hash(token), created: now, lastUsed: nil))
        try save()
        return token
    }

    /// The device a presented token belongs to, or nil. Takes the same time whether or not it matches.
    public func verify(_ presented: String, now: Date = Date()) -> RemoteToken? {
        let candidate = Array(Self.hash(presented).utf8)
        lock.lock(); defer { lock.unlock() }
        reloadIfChanged()
        var match: Int?
        for (i, t) in tokens.enumerated() {
            let stored = Array(t.hash.utf8)
            var diff = UInt8(stored.count == candidate.count ? 0 : 1)
            for j in 0..<min(stored.count, candidate.count) { diff |= stored[j] ^ candidate[j] }
            if diff == 0 { match = i }
        }
        guard let match else { return nil }
        tokens[match].lastUsed = now
        // "Last used" is a convenience for the menu; do not rewrite the file on every request.
        if now.timeIntervalSince(lastSaved) > 300 { try? save() }
        return tokens[match]
    }

    @discardableResult
    public func revoke(name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        reloadIfChanged()
        let before = tokens.count
        tokens.removeAll { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
        guard tokens.count != before else { return false }
        try? save()
        return true
    }

    public func revokeAll() {
        lock.lock(); defer { lock.unlock() }
        tokens.removeAll()
        try? save()
    }

    private func save() throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(tokens).write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        lastSaved = Date()
        loadedStamp = fileStamp
    }
}

/// Slows down guessing: after a few wrong tokens from one address, that address is refused for a while,
/// whatever it sends. Pure and clock-injected so it can be tested.
public final class AuthThrottle: @unchecked Sendable {
    public var maxFailures: Int
    public var window: TimeInterval
    public var lockout: TimeInterval
    private let lock = NSLock()
    private var failures: [String: [Date]] = [:]
    private var lockedUntil: [String: Date] = [:]

    public init(maxFailures: Int = 5, window: TimeInterval = 60, lockout: TimeInterval = 300) {
        self.maxFailures = maxFailures; self.window = window; self.lockout = lockout
    }

    /// Seconds until this address may try again; nil when it is not locked out.
    public func retryAfter(_ ip: String, now: Date = Date()) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let until = lockedUntil[ip] else { return nil }
        if until <= now { lockedUntil[ip] = nil; return nil }
        return max(1, Int(until.timeIntervalSince(now).rounded(.up)))
    }

    /// Records a wrong token. Returns true when this failure starts a lockout.
    @discardableResult
    public func recordFailure(_ ip: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var recent = (failures[ip] ?? []).filter { now.timeIntervalSince($0) < window }
        recent.append(now)
        failures[ip] = recent
        if failures.count > 512 { failures = failures.filter { $0.value.contains { now.timeIntervalSince($0) < window } } }
        guard recent.count >= maxFailures else { return false }
        failures[ip] = nil
        lockedUntil[ip] = now.addingTimeInterval(lockout)
        return true
    }

    public func recordSuccess(_ ip: String) {
        lock.lock(); failures[ip] = nil; lock.unlock()
    }
}
