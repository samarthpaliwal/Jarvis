import Foundation

/// Pulls calendar, reminders, Notion homework/exams, and assignment emails into one `BriefingData`.
/// Each source is optional: a missing or failing source is reported, never fatal.
public final class BriefingService: @unchecked Sendable {
    public struct Result: Sendable {
        public var data: BriefingData
        public var nextClass: BriefingData.Item?
        public var notes: [String]        // "Gmail not connected", etc.
        public var spoken: String
    }

    private let calendar: CalendarService
    private let notion: NotionClient
    private let gmail: GmailClient
    private let profile: () -> Profile

    public init(calendar: CalendarService, notion: NotionClient, gmail: GmailClient, profile: @escaping () -> Profile) {
        self.calendar = calendar; self.notion = notion; self.gmail = gmail; self.profile = profile
    }

    public func build(now: Date = Date(), mode: ModeDefinition) async -> Result {
        let p = profile()
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!
        let horizon = cal.date(byAdding: .day, value: p.briefing.examLookaheadDays, to: startOfDay)!
        var tasks: [BriefingData.Item] = []
        var deadlines: [(Date, BriefingData.Item)] = []
        var exams: [(Date, BriefingData.Item)] = []
        var notes: [String] = []
        var nextClass: BriefingData.Item?
        var timing: [String] = []
        func lap(_ name: String, _ t0: Date) { timing.append(String(format: "%@ %.0f ms", name, Date().timeIntervalSince(t0) * 1000)) }

        // Calendar: today's remaining events; exams/deadlines by keyword within the horizon.
        var t0 = Date()
        do {
            let events = try await calendar.events(from: now, to: horizon)
            let tf = DateFormatter(); tf.dateFormat = "h:mm a"
            for e in events {
                guard let start = e.start else { continue }
                let lower = e.title.lowercased()
                if start < endOfDay {
                    tasks.append(.init(title: e.title, detail: e.isAllDay ? "all day" : tf.string(from: start)))
                    if nextClass == nil, Self.looksLikeClass(lower, keywords: mode.triggers.calendarKeywords) {
                        nextClass = .init(title: e.title, detail: [tf.string(from: start), e.location].compactMap { $0 }.joined(separator: " · "))
                    }
                }
                if Self.examWords.contains(where: lower.contains) {
                    exams.append((start, .init(title: e.title, daysLeft: Self.days(from: startOfDay, to: start))))
                } else if Self.deadlineWords.contains(where: lower.contains) {
                    deadlines.append((start, .init(title: e.title, daysLeft: Self.days(from: startOfDay, to: start))))
                }
            }
        } catch { notes.append("Calendar: \(error.localizedDescription)") }
        lap("calendar", t0); t0 = Date()

        // Reminders due today → tasks; later → deadlines.
        if let reminders = try? await calendar.incompleteReminders(dueBefore: horizon) {
            for r in reminders {
                if let due = r.start, due >= endOfDay {
                    deadlines.append((due, .init(title: r.title, daysLeft: Self.days(from: startOfDay, to: due))))
                } else {
                    tasks.append(.init(title: r.title, detail: r.start == nil ? "reminder" : "due today"))
                }
            }
        }

        lap("reminders", t0); t0 = Date()

        // Notion homework and exams.
        let n = p.dataSources.notion
        if notion.isConfigured {
            if !n.homeworkDataSourceId.isEmpty {
                do {
                    let filter: JSONObject = ["and": [
                        ["property": n.homeworkStatusProperty, "select": ["does_not_equal": n.homeworkDoneValues.first ?? "Submitted"]],
                        ["property": n.homeworkDueProperty, "date": ["on_or_after": NotionClient.dateString(startOfDay)]],
                    ]]
                    let rows = try await notion.query(dataSource: n.homeworkDataSourceId, filter: filter,
                                                      sorts: [["property": n.homeworkDueProperty, "direction": "ascending"]])
                    for row in rows where !(row.status.map { n.homeworkDoneValues.contains($0) } ?? false) {
                        guard let due = row.date else { continue }
                        let cls = await row.relationIDs.first.asyncMap { await notion.pageTitle($0) } ?? nil
                        let title = cls.map { "\($0): \(row.title)" } ?? row.title
                        if due < endOfDay { tasks.append(.init(title: title, detail: "due today")) }
                        else { deadlines.append((due, .init(title: title, daysLeft: Self.days(from: startOfDay, to: due)))) }
                    }
                } catch { notes.append("Notion homework: \(error.localizedDescription)") }
            }
            if !n.examsDataSourceId.isEmpty {
                do {
                    let filter: JSONObject = ["and": [
                        ["property": n.examsDateProperty, "date": ["on_or_after": NotionClient.dateString(startOfDay)]],
                        ["property": n.examsDateProperty, "date": ["on_or_before": NotionClient.dateString(horizon)]],
                    ]]
                    let rows = try await notion.query(dataSource: n.examsDataSourceId, filter: filter,
                                                      sorts: [["property": n.examsDateProperty, "direction": "ascending"]])
                    for row in rows {
                        guard let date = row.date else { continue }
                        let cls = await row.relationIDs.first.asyncMap { await notion.pageTitle($0) } ?? nil
                        let title = cls.map { "\($0) \(row.title)" } ?? row.title
                        exams.append((date, .init(title: title, detail: row.location, daysLeft: Self.days(from: startOfDay, to: date))))
                    }
                } catch { notes.append("Notion exams: \(error.localizedDescription)") }
            }
        } else { notes.append("Notion not connected") }
        lap("notion", t0); t0 = Date()

        // Assignment / exam emails from the last week → deadlines hint.
        if gmail.isConnected {
            if let msgs = try? await gmail.search("newer_than:7d subject:(assignment OR exam OR quiz OR \"due\" OR homework OR midterm)", limit: 5) {
                for m in msgs {
                    deadlines.append((Date.distantFuture, .init(title: "Email: \(m.subject)", detail: String(m.from.prefix(24)))))
                }
            }
        } else { notes.append("Gmail not connected") }
        lap("gmail", t0)
        JarvisLog.info("Briefing timing: " + timing.joined(separator: ", "))

        // Merge and trim.
        let dedupTasks = Self.dedupe(tasks)
        let sortedDeadlines = Self.dedupe(deadlines.sorted { $0.0 < $1.0 }.map(\.1))
        let sortedExams = Self.dedupe(exams.sorted { $0.0 < $1.0 }.map(\.1))
        let data = BriefingData(tasks: Array(dedupTasks.prefix(6)),
                                deadlines: Array(sortedDeadlines.prefix(max(3, p.briefing.deadlineCount))),
                                exams: Array(sortedExams.prefix(4)))
        return Result(data: data, nextClass: nextClass, notes: notes, spoken: Self.spoken(data, name: p.assistant.addressUserAs, now: now, nextClass: nextClass, mode: mode))
    }

    static let examWords = ["exam", "midterm", "final", "quiz", "test "]
    static let deadlineWords = ["due", "deadline", "submit", "assignment", "homework", "project"]

    static func looksLikeClass(_ title: String, keywords: [String]) -> Bool {
        let defaults = ["lecture", "class", "lab", "section", "seminar"]
        return (keywords.map { $0.lowercased() } + defaults).contains { title.contains($0) }
            || title.range(of: #"\b[a-z]{2,4} ?\d{3}\b"#, options: .regularExpression) != nil
    }

    static func days(from: Date, to: Date) -> Int {
        Calendar.current.dateComponents([.day], from: from, to: Calendar.current.startOfDay(for: to)).day ?? 0
    }

    /// Synced calendar titles often carry junk like "[CSC120] Midterm 2 Today at 3:00pm". Clean for speech and dedupe.
    static func cleanTitle(_ t: String) -> String {
        var s = t.replacingOccurrences(of: #"\b(today|tomorrow)?\s*at\s*\d{1,2}(:\d{2})?\s*(am|pm)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"[\[\]]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
    }

    static func dedupe(_ items: [BriefingData.Item]) -> [BriefingData.Item] {
        var seen = Set<String>()
        return items.compactMap { item in
            var i = item
            i.title = cleanTitle(item.title)
            let key = i.title.lowercased()
            return seen.insert(key).inserted ? i : nil
        }
    }

    /// The one- or two-sentence spoken version.
    static func spoken(_ d: BriefingData, name: String, now: Date, nextClass: BriefingData.Item?, mode: ModeDefinition) -> String {
        let hour = Calendar.current.component(.hour, from: now)
        let greeting = hour < 12 ? "Morning" : hour < 17 ? "Afternoon" : "Evening"
        var parts: [String] = []
        let n = d.tasks.count
        parts.append(n == 0 ? "nothing left today" : n == 1 ? "one thing today: \(d.tasks[0].title)" : "\(n) things today")
        if let exam = d.exams.first, let days = exam.daysLeft {
            parts.append("your \(exam.title) is \(days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days")")
        } else if let dl = d.deadlines.first, let days = dl.daysLeft {
            parts.append("next deadline is \(dl.title) in \(days) day\(days == 1 ? "" : "s")")
        }
        var s = "\(greeting), \(name). " + parts.joined(separator: ", and ") + "."
        if mode.id == "class", let c = nextClass { s += " Next class: \(c.title)\(c.detail.map { ", \($0)" } ?? "")." }
        return s
    }
}
