import EventKit
import Foundation

/// What the calendar tools need. `CalendarService` implements it with EventKit; tests use a fake,
/// so no test ever touches the real calendar.
public protocol CalendarProviding: AnyObject, Sendable {
    func events(from: Date, to: Date) async throws -> [CalendarService.Item]
    func incompleteReminders(dueBefore: Date?) async throws -> [CalendarService.Item]
    @discardableResult
    func createEvent(title: String, start: Date, end: Date, location: String?, notes: String?, allDay: Bool) async throws -> CalendarService.Item
    /// Moves this one occurrence. Returns the event as it is afterwards.
    func moveEvent(_ item: CalendarService.Item, start: Date, end: Date) async throws -> CalendarService.Item
    /// Removes this one occurrence.
    func cancelEvent(_ item: CalendarService.Item) async throws
    func deleteEvent(id: String) throws
    @discardableResult
    func createReminder(title: String, due: Date?, notes: String?) async throws -> CalendarService.Item
    func deleteReminder(id: String) throws
}

/// EventKit wrapper: calendar events and reminders. Full-access prompts appear on first use.
public final class CalendarService: CalendarProviding, @unchecked Sendable {
    public struct Item: Equatable, Sendable {
        public var id: String
        public var title: String
        public var start: Date?
        public var end: Date?
        public var isAllDay: Bool
        public var location: String?
        public var calendar: String
        public var notes: String?
        public var isReminder: Bool
        /// Part of a repeating series. Moves and cancellations touch only this occurrence.
        public var isRecurring = false
        /// Other people invited. Changing the event may notify them.
        public var attendees = 0
        /// False for subscribed or read-only calendars (holidays, a shared class schedule).
        public var editable = true
    }

    public enum CalendarError: LocalizedError {
        case denied(String)
        case notFound(String)
        case readOnly(String)
        public var errorDescription: String? {
            switch self {
            case .denied(let what): return "\(what) access was not granted. System Settings → Privacy & Security → \(what)."
            case .notFound(let title): return "I couldn't find “\(title)” in the calendar any more."
            case .readOnly(let cal): return "That event is on “\(cal)”, which is read-only, so I can't change it."
            }
        }
    }

    public let store = EKEventStore()
    public init() {}

    public func requestEvents() async -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func requestReminders() async -> Bool {
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { return true }
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    public func events(from: Date, to: Date) async throws -> [Item] {
        guard await requestEvents() else { throw CalendarError.denied("Calendars") }
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: pred)
            .sorted { $0.startDate < $1.startDate }
            .map { e in
                Self.item(e)
            }
    }

    static func item(_ e: EKEvent) -> Item {
        Item(id: e.eventIdentifier ?? "", title: e.title ?? "(untitled)", start: e.startDate, end: e.endDate,
             isAllDay: e.isAllDay, location: e.location, calendar: e.calendar.title, notes: e.notes, isReminder: false,
             isRecurring: e.hasRecurrenceRules, attendees: (e.attendees ?? []).filter { !$0.isCurrentUser }.count,
             editable: e.calendar.allowsContentModifications)
    }

    /// The live event behind an item. Repeating events share one identifier, so the start time picks the occurrence.
    private func find(_ item: Item) throws -> EKEvent {
        guard let start = item.start else { throw CalendarError.notFound(item.title) }
        let pred = store.predicateForEvents(withStart: start.addingTimeInterval(-60), end: (item.end ?? start).addingTimeInterval(60), calendars: nil)
        guard let e = store.events(matching: pred).first(where: { $0.eventIdentifier == item.id && abs($0.startDate.timeIntervalSince(start)) < 60 }) else {
            throw CalendarError.notFound(item.title)
        }
        guard e.calendar.allowsContentModifications else { throw CalendarError.readOnly(e.calendar.title) }
        return e
    }

    public func moveEvent(_ item: Item, start: Date, end: Date) async throws -> Item {
        guard await requestEvents() else { throw CalendarError.denied("Calendars") }
        let e = try find(item)
        e.startDate = start
        e.endDate = end
        try store.save(e, span: .thisEvent, commit: true)
        return Self.item(e)
    }

    public func cancelEvent(_ item: Item) async throws {
        guard await requestEvents() else { throw CalendarError.denied("Calendars") }
        try store.remove(try find(item), span: .thisEvent, commit: true)
    }

    public func incompleteReminders(dueBefore: Date?) async throws -> [Item] {
        guard await requestReminders() else { throw CalendarError.denied("Reminders") }
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: dueBefore, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: pred) { cont.resume(returning: $0 ?? []) }
        }
        return reminders.map { r in
            Item(id: r.calendarItemIdentifier, title: r.title ?? "(untitled)", start: r.dueDateComponents?.date, end: nil,
                 isAllDay: r.dueDateComponents?.hour == nil, location: nil, calendar: r.calendar.title, notes: r.notes, isReminder: true)
        }.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    @discardableResult
    public func createEvent(title: String, start: Date, end: Date, location: String?, notes: String?, allDay: Bool) async throws -> Item {
        guard await requestEvents() else { throw CalendarError.denied("Calendars") }
        let e = EKEvent(eventStore: store)
        e.title = title; e.startDate = start; e.endDate = end; e.location = location; e.notes = notes; e.isAllDay = allDay
        e.calendar = store.defaultCalendarForNewEvents
        try store.save(e, span: .thisEvent, commit: true)
        return Item(id: e.eventIdentifier ?? "", title: title, start: start, end: end, isAllDay: allDay, location: location,
                    calendar: e.calendar.title, notes: notes, isReminder: false)
    }

    public func deleteEvent(id: String) throws {
        guard let e = store.event(withIdentifier: id) else { return }
        try store.remove(e, span: .thisEvent, commit: true)
    }

    @discardableResult
    public func createReminder(title: String, due: Date?, notes: String?) async throws -> Item {
        guard await requestReminders() else { throw CalendarError.denied("Reminders") }
        let r = EKReminder(eventStore: store)
        r.title = title; r.notes = notes
        r.calendar = store.defaultCalendarForNewReminders()
        if let due {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(r, commit: true)
        return Item(id: r.calendarItemIdentifier, title: title, start: due, end: nil, isAllDay: false, location: nil,
                    calendar: r.calendar.title, notes: notes, isReminder: true)
    }

    public func deleteReminder(id: String) throws {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try store.remove(r, commit: true)
    }
}

/// Natural-ish date parsing for tool inputs: ISO 8601, "2026-11-07 15:00", "tomorrow 3pm", "in 20 minutes".
public enum DateParsing {
    public static func parse(_ text: String, now: Date = Date()) -> Date? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: t) { return d }
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd h:mm a", "yyyy-MM-dd ha", "yyyy-MM-dd"] {
            let f = DateFormatter(); f.dateFormat = fmt; f.timeZone = .current; f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: t) { return d }
        }
        let lower = t.lowercased()
        if let m = lower.range(of: #"^in (\d+) (minute|min|hour|day)s?$"#, options: .regularExpression) {
            let parts = lower[m].split(separator: " ")
            let n = Double(parts[1]) ?? 0
            let unit = parts[2]
            let secs = unit.hasPrefix("hour") ? 3600.0 : unit.hasPrefix("day") ? 86400.0 : 60.0
            return now.addingTimeInterval(n * secs)
        }
        var base = Calendar.current.startOfDay(for: now)
        var rest = lower
        if lower.hasPrefix("tomorrow") { base = Calendar.current.date(byAdding: .day, value: 1, to: base)!; rest = String(lower.dropFirst(8)) }
        else if lower.hasPrefix("today") { rest = String(lower.dropFirst(5)) }
        else if let wd = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"].firstIndex(where: { lower.hasPrefix($0) }) {
            var d = base
            repeat { d = Calendar.current.date(byAdding: .day, value: 1, to: d)! } while Calendar.current.component(.weekday, from: d) != wd + 1
            base = d
            rest = String(lower.drop(while: { $0.isLetter }))
        } else { return nil }
        rest = rest.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "at ", with: "")
        if rest.isEmpty { return base.addingTimeInterval(9 * 3600) }
        for fmt in ["h:mma", "h:mm a", "ha", "h a", "HH:mm"] {
            let f = DateFormatter(); f.dateFormat = fmt; f.locale = Locale(identifier: "en_US_POSIX")
            if let time = f.date(from: rest) {
                let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                return Calendar.current.date(bySettingHour: c.hour ?? 9, minute: c.minute ?? 0, second: 0, of: base)
            }
        }
        return nil
    }
}
