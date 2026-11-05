import Foundation
import os

/// Unified logging: os_log (Console.app) + a plain text file at ~/Library/Logs/Jarvis/jarvis.log.
/// Tool calls get their own file (actions.log) in a later milestone.
public enum JarvisLog {
    private static let logger = Logger(subsystem: "com.samarth.jarvis", category: "app")
    private static let file = FileLog(name: "jarvis.log")

    public static var logDirectory: URL { FileLog.directory }

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        file.write(level: "INFO", message)
    }
    public static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        file.write(level: "WARN", message)
    }
    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        file.write(level: "ERROR", message)
    }
}

/// Append-only, timestamped text log. Thread-safe via a serial queue.
public final class FileLog: @unchecked Sendable {
    public static let directory: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Jarvis", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs
    }()

    public let url: URL
    private let queue = DispatchQueue(label: "com.samarth.jarvis.filelog")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(name: String) {
        url = FileLog.directory.appendingPathComponent(name)
    }

    public func write(level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        queue.async { [url] in
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
