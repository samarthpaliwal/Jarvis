import Foundation
import Security

/// Runs one key-helper command. The real one spawns `jarvis-keyhelper`; tests use a fake.
public protocol KeyHelperRunning: Sendable {
    /// Blocks until the helper answers (it may be waiting for Touch ID). Call off the main thread.
    func run(_ command: String, input: [String: Any], timeout: TimeInterval) throws -> [String: Any]
}

public enum VaultError: LocalizedError, Equatable {
    case helperFailed(String)
    case locked(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .helperFailed(let why): return "The key helper failed: \(why)"
        case .locked(let why): return "Keys are locked: \(why)"
        case .timedOut: return "The key helper did not answer in time."
        }
    }
}

/// Spawns the installed `jarvis-keyhelper` and talks JSON over its pipes.
public final class ProcessKeyHelper: KeyHelperRunning, @unchecked Sendable {
    public let url: URL

    /// The one copy that keeps macOS's approval: `~/Library/Application Support/Jarvis/bin/jarvis-keyhelper`.
    public static var installedURL: URL {
        ConfigLocator.userConfigDirectory.deletingLastPathComponent().appendingPathComponent("bin/jarvis-keyhelper")
    }

    public init?(url: URL = ProcessKeyHelper.installedURL) {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        self.url = url
    }

    public func run(_ command: String, input: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let process = Process()
        process.executableURL = url
        process.arguments = [command]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw VaultError.helperFailed(error.localizedDescription) }
        stdin.fileHandleForWriting.write((try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8))
        try? stdin.fileHandleForWriting.close()

        let finished = DispatchSemaphore(value: 0)
        var output = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            throw VaultError.timedOut
        }
        guard let reply = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any] else {
            throw VaultError.helperFailed("no answer (exit \(process.terminationStatus))")
        }
        if reply["ok"] as? Bool == true { return reply }
        let why = reply["error"] as? String ?? "unknown error"
        throw reply["locked"] as? Bool == true ? VaultError.locked(why) : VaultError.helperFailed(why)
    }
}

/// Every secret Jarvis uses, read once and kept in memory.
///
/// Two ways of working:
///  - **Helper** (normal): keys live in the key helper's vault. `unlock()` asks the helper once per launch,
///    which asks for Touch ID. After that `read` answers from memory: it never blocks and never prompts.
///  - **Legacy** (no helper installed): the old direct Keychain read, now cached, so macOS asks at most once
///    per key per launch instead of on every request.
public final class SecretVault: @unchecked Sendable {
    public static let shared = SecretVault()

    public enum State: Equatable, Sendable {
        case legacy                 // no helper: reading the Keychain directly
        case locked                 // helper present, not unlocked yet
        case unlocking
        case unlocked
        case failed(String)
    }

    /// Everything Jarvis may store. The helper is only ever asked about these.
    public static let accounts = ["ANTHROPIC_API_KEY", "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "GOOGLE_REFRESH_TOKEN",
                                  "NOTION_TOKEN", "SPOTIFY_CLIENT_ID", "SPOTIFY_CLIENT_SECRET", "ELEVENLABS_API_KEY", "OPENAI_API_KEY", "OLLAMA_API_KEY", "GOVEE_API_KEY"]

    public struct UnlockReport: Equatable, Sendable {
        public var state: State
        public var present: [String] = []
        public var imported: [String] = []
        public var denied: [String] = []
        public var needsApproval: [String] = []
    }

    private let lock = NSLock()
    private var helper: (any KeyHelperRunning)?
    private var cache: [String: String] = [:]
    private var legacyMisses: Set<String> = []
    private var stateValue: State = .legacy
    /// Keys that are still only in the old Keychain store. Until they are moved, they are read the old way
    /// (macOS may ask for the password, once per launch), so nothing that worked before stops working.
    private var notMovedYet: Set<String> = []
    /// Replaces the direct Keychain read in tests.
    var legacyReader: (@Sendable (String) -> String?)?

    public init(helper: (any KeyHelperRunning)? = nil) { configure(helper: helper) }

    public func configure(helper: (any KeyHelperRunning)?) {
        lock.lock(); defer { lock.unlock() }
        self.helper = helper
        cache = [:]; legacyMisses = []; notMovedYet = []
        stateValue = helper == nil ? .legacy : .locked
    }

    public var state: State { lock.lock(); defer { lock.unlock() }; return stateValue }
    public var usesHelper: Bool { lock.lock(); defer { lock.unlock() }; return helper != nil }

    // MARK: Reading

    /// The value, from memory. With the helper: nil until unlocked. Never prompts, never blocks.
    /// Without the helper: one direct Keychain read per key per launch (macOS may prompt that once).
    public func read(_ account: String) -> String? {
        lock.lock()
        if let v = cache[account] { lock.unlock(); return v }
        if helper != nil {
            // In the vault but not unlocked, or simply not set: nothing to give. Only a key that has not
            // been moved yet falls through to the old path below, and never while an unlock is on screen.
            guard notMovedYet.contains(account), stateValue != .unlocking else { lock.unlock(); return nil }
        }
        if legacyMisses.contains(account) { lock.unlock(); return nil }
        let reader = legacyReader
        lock.unlock()
        let value = reader.map { $0(account) } ?? Self.legacyRead(account)
        lock.lock()
        if let value { cache[account] = value } else { legacyMisses.insert(account) }
        lock.unlock()
        return value
    }

    // MARK: Unlocking (helper mode). Blocking: call off the main thread.

    /// Asks the helper for every key (Touch ID once). If the vault is still empty and older Keychain items
    /// exist, they are moved in first: macOS asks for the keychain password once per item, for the last time.
    @discardableResult
    public func unlock(importLegacy: Bool = true) -> UnlockReport {
        lock.lock()
        guard let helper else { lock.unlock(); return UnlockReport(state: .legacy) }
        if stateValue == .unlocking { lock.unlock(); return UnlockReport(state: .unlocking) }
        stateValue = .unlocking
        lock.unlock()

        var report = UnlockReport(state: .unlocked)
        do {
            let input: [String: Any] = ["accounts": Self.accounts]
            var command = "get"
            let status = try helper.run("status", input: input, timeout: 15)
            let inVault = Set(status["vault"] as? [String] ?? [])
            let old = (status["legacy"] as? [String] ?? []).filter { !inVault.contains($0) }
            lock.lock(); notMovedYet = Set(old); lock.unlock()
            if importLegacy, !old.isEmpty { command = "import" }
            let reply = try helper.run(command, input: input, timeout: command == "import" ? 600 : 180)
            let values = reply["values"] as? [String: String] ?? [:]
            report.present = values.keys.sorted()
            report.imported = (reply["imported"] as? [String] ?? []).sorted()
            report.denied = (reply["denied"] as? [String] ?? []).sorted()
            report.needsApproval = (reply["needs_approval"] as? [String] ?? []).sorted()
            lock.lock()
            cache = values; stateValue = .unlocked
            notMovedYet.subtract(values.keys)
            lock.unlock()
        } catch let e as VaultError {
            let s: State
            if case .locked = e { s = .locked } else { s = .failed(e.localizedDescription) }
            lock.lock(); stateValue = s; lock.unlock()
            report.state = s
        } catch {
            lock.lock(); stateValue = .failed(error.localizedDescription); lock.unlock()
            report.state = .failed(error.localizedDescription)
        }
        return report
    }

    // MARK: Writing

    public func write(_ value: String, account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); let helper = helper; lock.unlock()
        if let helper {
            _ = try helper.run("set", input: ["account": account, "value": trimmed], timeout: 30)
        } else {
            try Self.legacyWrite(trimmed, account: account)
        }
        lock.lock(); cache[account] = trimmed; legacyMisses.remove(account); lock.unlock()
    }

    public func delete(_ account: String) {
        lock.lock(); let helper = helper; cache[account] = nil; legacyMisses.insert(account); lock.unlock()
        if let helper { _ = try? helper.run("delete", input: ["account": account], timeout: 30) }
        else { Self.legacyDelete(account) }
    }

    /// Whether unlocking asks for Touch ID. Turning it off asks for Touch ID one last time.
    public func setRequiresTouchID(_ on: Bool) throws {
        lock.lock(); let helper = helper; lock.unlock()
        guard let helper else { return }
        _ = try helper.run("policy", input: ["require": on ? "touchid" : "none"], timeout: 180)
    }

    /// What is stored where, without revealing anything and without prompting.
    public func status() -> (vault: [String], legacy: [String], touchID: Bool)? {
        lock.lock(); let helper = helper; lock.unlock()
        guard let helper, let r = try? helper.run("status", input: ["accounts": Self.accounts], timeout: 15) else { return nil }
        return (r["vault"] as? [String] ?? [], r["legacy"] as? [String] ?? [], (r["policy"] as? String ?? "touchid") == "touchid")
    }

    // MARK: The old direct path (also the fallback when the helper is not installed)

    static let legacyService = "com.samarth.jarvis"

    static func legacyQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: legacyService, kSecAttrAccount as String: account]
    }

    static func legacyRead(_ account: String) -> String? {
        var query = legacyQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func legacyWrite(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(legacyQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = legacyQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Jarvis \(account)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainStore.KeychainError.status(status) }
    }

    static func legacyDelete(_ account: String) { SecItemDelete(legacyQuery(account) as CFDictionary) }
}
