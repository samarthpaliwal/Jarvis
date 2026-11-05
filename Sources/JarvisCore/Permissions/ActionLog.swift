import Foundation

/// Every tool call, as JSON lines in ~/Library/Logs/Jarvis/actions.log.
public struct ActionRecord: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var tool: String
    public var tier: Int
    public var source: String
    public var input: String
    public var outcome: String   // ran | denied | refused | failed | approved | rejected
    public var summary: String?
    public var durationMs: Int?
}

public final class ActionLog: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "com.samarth.jarvis.actionlog")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    public init(url: URL = FileLog.directory.appendingPathComponent("actions.log")) {
        self.url = url
    }

    public func record(_ r: ActionRecord) {
        guard var data = try? encoder.encode(r) else { return }
        data.append(0x0A)
        queue.async { [url] in
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    public func records(since: Date) -> [ActionRecord] {
        queue.sync {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                try? decoder.decode(ActionRecord.self, from: Data(line.utf8))
            }.filter { $0.timestamp >= since }
        }
    }

    /// "What did you do today" lines.
    public func todaySummary(now: Date = Date()) -> [String] {
        let start = Calendar.current.startOfDay(for: now)
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return records(since: start).map { r in
            "\(f.string(from: r.timestamp)) \(r.tool) · \(r.outcome)" + (r.summary.map { " · \($0)" } ?? "")
        }
    }
}
