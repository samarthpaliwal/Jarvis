import Foundation
import SQLite3

/// Persistent memory, adapted from OpenJarvis (MEMORY.md / USER.md + a SQLite FTS5 store):
///  - `MEMORY.md`: durable facts Jarvis learned ("Sam's CSC 210 lab is in Gould-Simpson 701")
///  - `USER.md`:   preferences about Sam ("prefers Celsius", "gym at 6am")
///  - `memory.db`: full-text index of past conversations and saved notes, for "what did I ask you yesterday"
/// Everything stays in ~/Library/Application Support/Jarvis. Nothing here is synced anywhere.
public final class MemoryStore: @unchecked Sendable {
    public enum Scope: String, CaseIterable, Sendable { case facts, profile }
    public struct Hit: Equatable, Sendable { public var kind: String; public var text: String; public var date: Date; public var score: Double }

    public let directory: URL
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.samarth.jarvis.memory")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public static let maxEntryLength = 400
    public static let maxInjectedChars = 2500

    public init(directory: URL = ConfigLocator.userConfigDirectory.deletingLastPathComponent()) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queue.sync { openDatabase() }
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: Facts / profile (markdown bullet lists)

    public func url(for scope: Scope) -> URL { directory.appendingPathComponent(scope == .facts ? "MEMORY.md" : "USER.md") }

    public func entries(_ scope: Scope) -> [String] {
        queue.sync { readEntries(scope) }
    }

    private func readEntries(_ scope: Scope) -> [String] {
        guard let text = try? String(contentsOf: url(for: scope), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") else { return nil }
            return String(t.dropFirst(2))
        }
    }

    private func writeEntries(_ entries: [String], _ scope: Scope) throws {
        let header = scope == .facts ? "# Jarvis memory\n\nThings Jarvis has learned. Edit freely.\n\n" : "# About Sam\n\nPreferences Jarvis follows. Edit freely.\n\n"
        try (header + entries.map { "- \($0)" }.joined(separator: "\n") + "\n").write(to: url(for: scope), atomically: true, encoding: .utf8)
    }

    public enum MemoryError: LocalizedError, Equatable {
        case empty, tooLong, secret(String), notFound(String), duplicate
        public var errorDescription: String? {
            switch self {
            case .empty: return "Nothing to remember."
            case .tooLong: return "That's too long for one memory (\(MemoryStore.maxEntryLength) characters max)."
            case .secret(let what): return "That looks like a secret (\(what)). I don't store credentials."
            case .notFound(let e): return "No memory matching “\(e)”."
            case .duplicate: return "Already remembered."
            }
        }
    }

    public func add(_ entry: String, to scope: Scope) throws {
        let e = entry.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !e.isEmpty else { throw MemoryError.empty }
        guard e.count <= Self.maxEntryLength else { throw MemoryError.tooLong }
        if let kind = SecretRedactor.findings(in: e).first { throw MemoryError.secret(kind) }
        try queue.sync {
            var list = readEntries(scope)
            guard !list.contains(where: { $0.caseInsensitiveCompare(e) == .orderedSame }) else { throw MemoryError.duplicate }
            list.append(e)
            try writeEntries(list, scope)
            insert(kind: "note:\(scope.rawValue)", text: e)
        }
    }

    /// Removes the first entry containing `match` (case-insensitive). Returns the removed text.
    @discardableResult
    public func remove(matching match: String, from scope: Scope) throws -> String {
        try queue.sync {
            var list = readEntries(scope)
            guard let i = list.firstIndex(where: { $0.localizedCaseInsensitiveContains(match) }) else { throw MemoryError.notFound(match) }
            let removed = list.remove(at: i)
            try writeEntries(list, scope)
            return removed
        }
    }

    public func update(matching match: String, with new: String, in scope: Scope) throws -> String {
        let removed = try remove(matching: match, from: scope)
        do { try add(new, to: scope) } catch { try? add(removed, to: scope); throw error }
        return removed
    }

    /// The block injected into the system prompt every turn (capped).
    public func promptBlock() -> String? {
        let facts = entries(.facts), profile = entries(.profile)
        guard !facts.isEmpty || !profile.isEmpty else { return nil }
        var s = "What you remember (from your persistent memory; use it naturally, don't recite it):"
        if !profile.isEmpty { s += "\nAbout Sam: " + profile.joined(separator: "; ") }
        if !facts.isEmpty { s += "\nFacts: " + facts.joined(separator: "; ") }
        return s.count > Self.maxInjectedChars ? String(s.prefix(Self.maxInjectedChars)) + "…" : s
    }

    // MARK: Conversation archive + search (SQLite FTS5)

    public func archive(user: String, jarvis: String, tools: [String]) {
        guard !user.isEmpty else { return }
        let redacted = SecretRedactor.redact("You: \(user)\nJarvis: \(jarvis)" + (tools.isEmpty ? "" : "\nTools: \(tools.joined(separator: ", "))")).text
        queue.async { [weak self] in self?.insert(kind: "conversation", text: redacted) }
    }

    public func search(_ query: String, limit: Int = 6) -> [Hit] {
        let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
        guard !terms.isEmpty else { return [] }
        // Each term quoted (FTS5-safe), OR-ed so partial matches still rank.
        let match = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        return queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            let sql = "SELECT kind, text, created, bm25(memory) FROM memory WHERE memory MATCH ? ORDER BY bm25(memory) LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, match, -1, Self.transient)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var hits: [Hit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                hits.append(Hit(kind: String(cString: sqlite3_column_text(stmt, 0)), text: String(cString: sqlite3_column_text(stmt, 1)),
                                date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)), score: -sqlite3_column_double(stmt, 3)))
            }
            return hits
        }
    }

    public func recentConversations(limit: Int = 5) -> [Hit] {
        queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT kind, text, created FROM memory WHERE kind = 'conversation' ORDER BY created DESC LIMIT ?", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var hits: [Hit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                hits.append(Hit(kind: String(cString: sqlite3_column_text(stmt, 0)), text: String(cString: sqlite3_column_text(stmt, 1)),
                                date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)), score: 0))
            }
            return hits
        }
    }

    public func count() -> Int {
        queue.sync {
            guard let db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM memory", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    /// Forget all archived conversations (facts/profile files are untouched).
    public func clearConversations() {
        queue.sync { _ = sqlite3_exec(db, "DELETE FROM memory WHERE kind = 'conversation'", nil, nil, nil) }
    }

    // MARK: SQLite plumbing (always on `queue`)

    private func openDatabase() {
        let path = directory.appendingPathComponent("memory.db").path
        guard sqlite3_open(path, &db) == SQLITE_OK else { JarvisLog.error("memory.db open failed"); db = nil; return }
        let ok = sqlite3_exec(db, "CREATE VIRTUAL TABLE IF NOT EXISTS memory USING fts5(kind UNINDEXED, text, created UNINDEXED, tokenize='porter unicode61')", nil, nil, nil)
        if ok != SQLITE_OK { JarvisLog.error("memory.db FTS5 unavailable (\(ok))") }
    }

    private func insert(kind: String, text: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO memory(kind, text, created) VALUES (?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, kind, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, text, -1, Self.transient)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }
}
