import Foundation

/// What Jarvis keeps, and for how long. Applied at launch and once a day.
///
/// | What | Where | Kept |
/// |---|---|---|
/// | What was said (you and Jarvis) | conversations.log | `retainConversationsDays` (30) |
/// | Timings per request, no words | trace.jsonl | `retainTraceDays` (30) |
/// | Diagnostics | jarvis.log | `retainLogDays` (14) |
/// | Every tool call (the audit trail) | actions.log | `retainActionsDays` (90) |
/// | Photos and videos you asked for | ~/Pictures/Jarvis, ~/Movies/Jarvis | forever, unless `retainMediaDays` is set; then moved to the Trash |
///
/// 0 days means "keep forever". Nothing outside these files and folders is ever touched, and media is
/// only ever moved to the Trash, never deleted.
public enum Retention {
    public struct Policy: Equatable, Sendable {
        public var conversationsDays: Double
        public var traceDays: Double
        public var logDays: Double
        public var actionsDays: Double
        public var mediaDays: Double
        public init(conversationsDays: Double = 30, traceDays: Double = 30, logDays: Double = 14, actionsDays: Double = 90, mediaDays: Double = 0) {
            self.conversationsDays = conversationsDays; self.traceDays = traceDays; self.logDays = logDays; self.actionsDays = actionsDays; self.mediaDays = mediaDays
        }
        public init(_ t: Tuning) {
            self.init(conversationsDays: t.retainConversationsDays, traceDays: t.retainTraceDays, logDays: t.retainLogDays, actionsDays: t.retainActionsDays, mediaDays: t.retainMediaDays)
        }
        var logs: [(file: String, days: Double)] {
            [("conversations.log", conversationsDays), ("trace.jsonl", traceDays), ("jarvis.log", logDays), ("actions.log", actionsDays)]
        }
    }

    public struct Report: Equatable, Sendable {
        public var linesRemoved = 0
        public var filesRemoved = 0
        public var mediaTrashed = 0
        public var isEmpty: Bool { linesRemoved == 0 && filesRemoved == 0 && mediaTrashed == 0 }
    }

    private static let stamp = try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"#)
    private static func parser() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }

    /// The time a log line was written: the first timestamp in it (plain lines start with one, JSON lines carry one).
    static func date(of line: Substring, using f: DateFormatter) -> Date? {
        let head = String(line.prefix(400))
        guard let m = stamp.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)), let r = Range(m.range, in: head) else { return nil }
        return f.date(from: String(head[r]))
    }

    /// Drops every line older than `cutoff`. A line without a timestamp belongs to the line before it.
    public static func prune(_ text: String, olderThan cutoff: Date) -> (text: String, removed: Int) {
        let f = parser()
        var kept: [Substring] = []
        var removed = 0
        var keeping = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let d = date(of: line, using: f) { keeping = d >= cutoff }
            if keeping { kept.append(line) } else if !line.isEmpty { removed += 1 }
        }
        return (kept.joined(separator: "\n"), removed)
    }

    /// Applies the policy to the log folder and, if asked, the media folders.
    @discardableResult
    public static func sweep(_ policy: Policy, logs: URL = FileLog.directory, media: [URL] = [], now: Date = Date()) -> Report {
        var report = Report()
        let fm = FileManager.default
        for (file, days) in policy.logs where days > 0 {
            let cutoff = now.addingTimeInterval(-days * 86_400)
            let live = logs.appendingPathComponent(file)
            report.linesRemoved += FileLog.rewrite(live) { prune($0, olderThan: cutoff) }
            // Rotated copies (name.1, name.2 …): gone once nothing in them is recent enough.
            for n in 1...20 {
                let old = URL(fileURLWithPath: live.path + ".\(n)")
                guard let modified = (try? fm.attributesOfItem(atPath: old.path))?[.modificationDate] as? Date else { continue }
                if modified < cutoff { if (try? fm.removeItem(at: old)) != nil { report.filesRemoved += 1 } }
                else { report.linesRemoved += FileLog.rewrite(old) { prune($0, olderThan: cutoff) } }
            }
        }
        if policy.mediaDays > 0 {
            let cutoff = now.addingTimeInterval(-policy.mediaDays * 86_400)
            for folder in media {
                for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles])) ?? [] {
                    let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                    guard values?.isRegularFile == true, let modified = values?.contentModificationDate, modified < cutoff,
                          item.lastPathComponent.hasPrefix("Jarvis ") else { continue }      // only files Jarvis named
                    if (try? fm.trashItem(at: item, resultingItemURL: nil)) != nil { report.mediaTrashed += 1 }
                }
            }
        }
        return report
    }
}
