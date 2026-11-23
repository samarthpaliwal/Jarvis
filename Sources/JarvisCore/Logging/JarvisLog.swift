import Foundation
import os

/// Unified logging: os_log (Console.app) plus files in ~/Library/Logs/Jarvis:
///   jarvis.log         human-readable, one line per event; lines inside a request carry its ID: `[r-3fa9c1]`
///   trace.jsonl        structured, one JSON object per pipeline stage and one summary per request
///   actions.log        every tool call (JSON lines)
///   conversations.log  what was said, secrets redacted
public enum JarvisLog {
    private static let logger = Logger(subsystem: "com.samarth.jarvis", category: "app")
    private static let file = FileLog(name: "jarvis.log")
    private static let chat = FileLog(name: "conversations.log")

    /// Every exchange, in plain text: ~/Library/Logs/Jarvis/conversations.log (secrets redacted).
    public static func conversation(you: String, jarvis: String, tools: [String]) {
        let t = tools.isEmpty ? "" : "  [tools: \(tools.joined(separator: ", "))]"
        chat.write(level: "CHAT", tagged(SecretRedactor.redact("You: \(you)\n    Jarvis: \(jarvis)\(t)").text, nil))
    }

    /// Marks the end of a chat session in conversations.log.
    public static func conversationEnded() {
        chat.write(level: "CHAT", "— chat ended —")
    }

    public static var logDirectory: URL { FileLog.directory }

    /// `request`: pass an ID explicitly from code that runs outside the request's task
    /// (callbacks from the microphone or the recognizer). Inside the task it is picked up automatically.
    public static func info(_ message: String, request: String? = nil) {
        let m = tagged(message, request)
        logger.info("\(m, privacy: .public)")
        file.write(level: "INFO", m)
    }
    public static func warn(_ message: String, request: String? = nil) {
        let m = tagged(message, request)
        logger.warning("\(m, privacy: .public)")
        file.write(level: "WARN", m)
    }
    public static func error(_ message: String, request: String? = nil) {
        let m = tagged(message, request)
        logger.error("\(m, privacy: .public)")
        file.write(level: "ERROR", m)
    }

    private static func tagged(_ message: String, _ request: String?) -> String {
        guard let id = request ?? RequestTrace.current?.id else { return message }
        return "[\(id)] \(message)"
    }
}

/// Append-only, timestamped text log. Thread-safe via a serial queue. Rotates by size:
/// jarvis.log → jarvis.log.1 → jarvis.log.2 …, keeping `keepFiles` old files.
public final class FileLog: @unchecked Sendable {
    /// Unit tests write to a temporary folder so they never pollute the real logs (they used to,
    /// which skewed the latency numbers).
    public static let directory: URL = {
        let logs: URL
        if Runtime.isTesting {
            logs = FileManager.default.temporaryDirectory.appendingPathComponent("JarvisTests-logs-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else {
            logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Jarvis", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs
    }()

    /// Rotation limits, shared by every log file. Set from Tuning at launch.
    public nonisolated(unsafe) static var maxBytes: Int = 5 * 1024 * 1024
    public nonisolated(unsafe) static var keepFiles: Int = 3

    public let url: URL
    private let queue = DispatchQueue(label: "com.samarth.jarvis.filelog")
    private var size: Int?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(name: String) {
        url = FileLog.directory.appendingPathComponent(name)
        Self.register(self)
    }

    public init(url: URL) { self.url = url; Self.register(self) }

    // Open logs by path, so the retention sweep can rewrite a file through the same queue that appends to it.
    private final class Weak { weak var log: FileLog?; init(_ l: FileLog) { log = l } }
    private static let registryLock = NSLock()
    private nonisolated(unsafe) static var registry: [String: Weak] = [:]
    private static func register(_ log: FileLog) { registryLock.lock(); registry[log.url.standardizedFileURL.path] = Weak(log); registryLock.unlock() }

    /// Replaces a log's contents with `transform(contents)`, without racing a writer. Returns the count `transform` reports.
    @discardableResult
    public static func rewrite(_ url: URL, _ transform: (String) -> (text: String, removed: Int)) -> Int {
        registryLock.lock(); let open = registry[url.standardizedFileURL.path]?.log; registryLock.unlock()
        func apply() -> Int {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return 0 }
            let result = transform(text)
            guard result.removed > 0 else { return 0 }
            guard (try? Data(result.text.utf8).write(to: url, options: .atomic)) != nil else { return 0 }
            return result.removed
        }
        guard let open else { return apply() }
        return open.queue.sync { let n = apply(); if n > 0 { open.size = nil }; return n }
    }

    public func write(level: String, _ message: String) {
        append("\(formatter.string(from: Date())) [\(level)] \(message)\n")
    }

    /// Writes one line exactly as given (used for JSON lines).
    public func writeRaw(_ line: String) { append(line + "\n") }

    /// Blocks until everything queued so far is on disk. For tests and shutdown.
    public func flush() { queue.sync {} }

    private func append(_ line: String) {
        queue.async { [self] in
            guard let data = line.data(using: .utf8) else { return }
            if size == nil {
                size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            }
            if let s = size, s > 0, s + data.count > Self.maxBytes { rotate() }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
            size = (size ?? 0) + data.count
        }
    }

    /// name → name.1 → name.2 … ; the oldest beyond `keepFiles` is deleted. Queue only.
    private func rotate() {
        let fm = FileManager.default
        let keep = max(0, Self.keepFiles)
        func numbered(_ n: Int) -> URL { URL(fileURLWithPath: url.path + ".\(n)") }
        if keep == 0 {
            try? fm.removeItem(at: url)
        } else {
            try? fm.removeItem(at: numbered(keep))
            for n in stride(from: keep - 1, through: 1, by: -1) where fm.fileExists(atPath: numbered(n).path) {
                try? fm.moveItem(at: numbered(n), to: numbered(n + 1))
            }
            try? fm.moveItem(at: url, to: numbered(1))
        }
        size = 0
    }
}
