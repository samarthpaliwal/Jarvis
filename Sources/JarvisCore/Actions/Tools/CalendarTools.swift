import Foundation

private let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE MMM d, h:mm a"; return f }()
private let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE MMM d"; return f }()

func describe(_ i: CalendarService.Item) -> String {
    var s = i.title
    if let st = i.start { s += " · " + (i.isAllDay ? dayFormatter.string(from: st) : timeFormatter.string(from: st)) }
    if let loc = i.location, !loc.isEmpty { s += " @ \(loc)" }
    return s
}

/// How an event is spoken in a confirmation: "“Calculus” on Fri Nov 27 at 9:00 AM".
func spokenEvent(_ i: CalendarService.Item) -> String {
    guard let st = i.start else { return "“\(i.title)”" }
    let t = DateFormatter(); t.dateFormat = "h:mm a"
    return "“\(i.title)” on \(dayFormatter.string(from: st))" + (i.isAllDay ? "" : " at \(t.string(from: st))")
}

/// Finds the one event a spoken request means: "my calculus class tomorrow".
public enum CalendarMatcher {
    public enum Failure: Error, Equatable {
        case none(onDay: [String])
        case several([String])
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { !["my", "the", "a", "an", "class", "meeting", "event", "appointment", "with", "for"].contains($0) }
    }

    /// `at` narrows it when two events on the day match ("the 3 o'clock one").
    public static func resolve(title: String, at: Date? = nil, in events: [CalendarService.Item]) -> Result<CalendarService.Item, Failure> {
        let wanted = words(title)
        var matches = events.filter { e in
            let have = words(e.title)
            let whole = e.title.lowercased()
            return !wanted.isEmpty && wanted.allSatisfy { w in have.contains { $0.hasPrefix(w) || w.hasPrefix($0) } || whole.contains(w) }
        }
        if let at, matches.count != 1 {
            let pool = matches.isEmpty ? events : matches
            let near = pool.filter { abs(($0.start ?? .distantPast).timeIntervalSince(at)) <= 10 * 60 }
            if !near.isEmpty && (!matches.isEmpty || wanted.isEmpty) { matches = near }
        }
        if matches.count == 1 { return .success(matches[0]) }
        if matches.isEmpty { return .failure(.none(onDay: events.map(describe))) }
        return .failure(.several(matches.map(describe)))
    }

    /// The text handed back to the model when the event is unclear, so it can ask a useful question.
    public static func explain(_ f: Failure, title: String, day: String) -> String {
        switch f {
        case .none(let onDay):
            return onDay.isEmpty ? "There is nothing on the calendar \(day), so there is no “\(title)” to change."
                                 : "No event matching “\(title)” \(day). That day has: \(onDay.joined(separator: "; ")). Ask which one, or use its exact title."
        case .several(let list):
            return "More than one event matches “\(title)” \(day): \(list.joined(separator: "; ")). Ask which one, then pass its start time in `at`."
        }
    }
}

/// One event, or the message to hand back to the model.
enum ResolvedEvent {
    case success(CalendarService.Item)
    case failure(ToolResult)
}

/// Shared by move and cancel: turn (title, date, at) into one event.
@MainActor
func resolveEvent(_ input: JSONObject, calendar: any CalendarProviding, now: Date = Date()) async throws -> ResolvedEvent {
    guard let title = input.string("title"), !title.isEmpty else { return .failure(.error("title is required")) }
    let dayText = input.string("date") ?? "today"
    guard let day = DateParsing.parse(dayText, now: now) ?? DateParsing.parse(dayText + " 9am", now: now) else {
        return .failure(.error("I couldn't understand the date “\(dayText)”."))
    }
    let startOfDay = Calendar.current.startOfDay(for: day)
    let events = try await calendar.events(from: startOfDay, to: startOfDay.addingTimeInterval(86_400))
    let at = input.string("at").flatMap { DateParsing.parse("\(isoDay(startOfDay)) \($0)", now: now) ?? DateParsing.parse($0, now: now) }
    switch CalendarMatcher.resolve(title: title, at: at, in: events) {
    case .success(let item): return .success(item)
    case .failure(let f): return .failure(.error(CalendarMatcher.explain(f, title: title, day: "on \(dayFormatter.string(from: startOfDay))")))
    }
}

private func isoDay(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: d)
}

/// Tier 0: calendar events and reminders in a window.
public final class CalendarReadTool: JarvisTool {
    public let name = "calendar_read"
    public let description = "Read calendar events (all accounts in macOS Calendar, incl. Google) and incomplete reminders. Default: the next 24 hours. Use days (1–30) to look further ahead, and date ('tomorrow', 'friday', 'YYYY-MM-DD') to start from the beginning of another day."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": [
            "days": ["type": "integer", "minimum": 1, "maximum": 30],
            "date": ["type": "string"],
            "include_reminders": ["type": "boolean"],
        ],
        "additionalProperties": false,
    ]
    private let calendar: any CalendarProviding
    public init(calendar: any CalendarProviding) { self.calendar = calendar }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let days = input.int("days") ?? 1
        var now = Date()
        if let d = input.string("date"), let parsed = DateParsing.parse(d) ?? DateParsing.parse(d + " 9am") {
            now = Calendar.current.startOfDay(for: parsed)
        }
        let end = Calendar.current.date(byAdding: .day, value: days, to: now)!
        var lines = try await calendar.events(from: now, to: end).map { e -> String in
            var flags: [String] = []
            if e.isRecurring { flags.append("repeats") }
            if e.attendees > 0 { flags.append("\(e.attendees) invited") }
            if !e.editable { flags.append("read-only") }
            return "Event: " + describe(e) + (flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))")
        }
        if input.bool("include_reminders") ?? true {
            let reminders = (try? await calendar.incompleteReminders(dueBefore: end)) ?? []
            lines += reminders.map { "Reminder: " + describe($0) }
        }
        if lines.isEmpty { return ToolResult("Nothing on the calendar in the next \(days) day(s).") }
        return ToolResult(Untrusted.wrap(lines.joined(separator: "\n"), source: "calendar"),
                          card: .info(title: "Next \(days) day(s)", lines: Array(lines.prefix(6))))
    }
}

/// Tier 1: create an event (undoable: delete).
public final class CalendarCreateTool: JarvisTool {
    public let name = "calendar_create"
    public let description = "Create a calendar event. start/end accept ISO 8601, 'YYYY-MM-DD HH:mm', 'tomorrow 3pm', 'friday 10am'. Default duration 1 hour."
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "start": ["type": "string"],
            "end": ["type": "string"],
            "location": ["type": "string"],
            "notes": ["type": "string"],
            "all_day": ["type": "boolean"],
        ],
        "required": ["title", "start"], "additionalProperties": false,
    ]
    private let calendar: any CalendarProviding
    public init(calendar: any CalendarProviding) { self.calendar = calendar }

    public func preview(for input: JSONObject) -> String { "event “\(input.string("title") ?? "")” at \(input.string("start") ?? "")" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let title = input.string("title"), let startText = input.string("start"),
              let start = DateParsing.parse(startText) else { return .error("I couldn't understand the start time.") }
        let end = input.string("end").flatMap { DateParsing.parse($0) } ?? start.addingTimeInterval(3600)
        let item = try await calendar.createEvent(title: title, start: start, end: end, location: input.string("location"),
                                                  notes: input.string("notes"), allDay: input.bool("all_day") ?? false)
        let id = item.id
        let cal = calendar
        await context.undo.push(.init(description: "event “\(title)”") { try cal.deleteEvent(id: id); return "Deleted the event “\(title)”." })
        return ToolResult("Created: \(describe(item))", summary: "Event: \(describe(item))")
    }
}

/// Tier 1: Apple Reminders (undoable: delete).
public final class SetReminderTool: JarvisTool {
    public let name = "set_reminder"
    public let description = "Create a reminder in Apple Reminders with an optional due time ('tomorrow 9am', 'in 2 hours', ISO 8601)."
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": ["title": ["type": "string"], "due": ["type": "string"], "notes": ["type": "string"]],
        "required": ["title"], "additionalProperties": false,
    ]
    private let calendar: any CalendarProviding
    public init(calendar: any CalendarProviding) { self.calendar = calendar }

    public func preview(for input: JSONObject) -> String { "reminder “\(input.string("title") ?? "")”" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let title = input.string("title") else { return .error("title is required") }
        let due = input.string("due").flatMap { DateParsing.parse($0) }
        let item = try await calendar.createReminder(title: title, due: due, notes: input.string("notes"))
        let id = item.id
        let cal = calendar
        await context.undo.push(.init(description: "reminder “\(title)”") { try cal.deleteReminder(id: id); return "Removed the reminder “\(title)”." })
        return ToolResult("Reminder set: \(describe(item))", summary: "Reminder: \(describe(item))")
    }
}

/// Tier 1: move an event (undoable: move it back). Asks first when other people are invited.
public final class CalendarMoveTool: JarvisTool {
    public let name = "calendar_move"
    public let description = "Move (reschedule) one calendar event. Identify it by title and the day it is on now; give the new start. Keeps the same length unless new_end is given. For a repeating event only this occurrence moves. If other people are invited, the user is asked first because they may be notified."
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "Title or a few words of it, e.g. 'calculus'."],
            "date": ["type": "string", "description": "The day the event is on now: 'today', 'tomorrow', 'friday', 'YYYY-MM-DD'. Default today."],
            "at": ["type": "string", "description": "Its current start time, only to tell two matching events apart, e.g. '3pm'."],
            "new_start": ["type": "string", "description": "'tomorrow 3pm', 'friday 10am', 'YYYY-MM-DD HH:mm', ISO 8601."],
            "new_end": ["type": "string"],
        ],
        "required": ["title", "new_start"], "additionalProperties": false,
    ]
    private let calendar: any CalendarProviding
    public init(calendar: any CalendarProviding) { self.calendar = calendar }

    public func preview(for input: JSONObject) -> String { "move “\(input.string("title") ?? "")” to \(input.string("new_start") ?? "")" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let item: CalendarService.Item
        switch try await resolveEvent(input, calendar: calendar) {
        case .success(let i): item = i
        case .failure(let r): return r
        }
        guard item.editable else { return .error(CalendarService.CalendarError.readOnly(item.calendar).localizedDescription) }
        guard let oldStart = item.start, let startText = input.string("new_start"),
              let newStart = DateParsing.parse(startText) else { return .error("I couldn't understand the new time.") }
        let length = (item.end ?? oldStart.addingTimeInterval(3600)).timeIntervalSince(oldStart)
        let newEnd = input.string("new_end").flatMap { DateParsing.parse($0) } ?? newStart.addingTimeInterval(length)
        guard newEnd > newStart else { return .error("The new end is before the new start.") }
        let when = timeFormatter.string(from: newStart)
        // Other people would be told about the change: that is a message sent on Sam's behalf, so ask.
        if item.attendees > 0 {
            let others = item.attendees == 1 ? "1 other person is" : "\(item.attendees) other people are"
            guard await ToolDispatcher.confirm("Move \(spokenEvent(item)) to \(when). \(others) invited and may be notified") else {
                return .error("Sam did not approve moving “\(item.title)”. Nothing was changed.")
            }
        }
        let moved = try await calendar.moveEvent(item, start: newStart, end: newEnd)
        let cal = calendar
        let oldEnd = oldStart.addingTimeInterval(length)
        await context.undo.push(.init(description: "moving “\(item.title)”") {
            _ = try await cal.moveEvent(moved, start: oldStart, end: oldEnd)
            return "Moved “\(item.title)” back to \(timeFormatter.string(from: oldStart))."
        })
        let note = item.isRecurring ? " Only this occurrence moved; the rest of the series is unchanged." : ""
        return ToolResult("Moved “\(item.title)” from \(timeFormatter.string(from: oldStart)) to \(when).\(note)",
                          summary: "Moved “\(item.title)” to \(when)")
    }
}

/// Tier 2: cancel (delete) an event. Always asks first, naming the exact event.
public final class CalendarCancelTool: JarvisTool {
    public let name = "calendar_cancel"
    public let description = "Cancel (delete) one calendar event. Identify it by title and the day it is on. The user must approve; the approval names the exact event. For a repeating event only this occurrence is removed."
    public let tier = Tier.approve
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "Title or a few words of it."],
            "date": ["type": "string", "description": "The day it is on: 'today', 'tomorrow', 'friday', 'YYYY-MM-DD'. Default today."],
            "at": ["type": "string", "description": "Its start time, only to tell two matching events apart."],
        ],
        "required": ["title"], "additionalProperties": false,
    ]
    private let calendar: any CalendarProviding
    public init(calendar: any CalendarProviding) { self.calendar = calendar }

    public func preview(for input: JSONObject) -> String { "Cancel the event “\(input.string("title") ?? "")” \(input.string("date") ?? "today")" }

    public func refusal(for input: JSONObject, context: ToolContext) async -> String? {
        guard let resolved = try? await resolveEvent(input, calendar: calendar) else { return nil }
        switch resolved {
        case .failure(let r): return r.content
        case .success(let item): return item.editable ? nil : CalendarService.CalendarError.readOnly(item.calendar).localizedDescription
        }
    }

    /// The approval names the event that will really be deleted, not just what was asked for.
    public func approvalPreview(for input: JSONObject, context: ToolContext) async -> String {
        guard let resolved = try? await resolveEvent(input, calendar: calendar), case .success(let item) = resolved else { return preview(for: input) }
        var s = "Cancel \(spokenEvent(item))"
        if item.isRecurring { s += ", this occurrence only" }
        if item.attendees > 0 { s += ". \(item.attendees) other \(item.attendees == 1 ? "person is" : "people are") invited and may be notified" }
        return s
    }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let item: CalendarService.Item
        switch try await resolveEvent(input, calendar: calendar) {
        case .success(let i): item = i
        case .failure(let r): return r
        }
        guard item.editable else { return .error(CalendarService.CalendarError.readOnly(item.calendar).localizedDescription) }
        try await calendar.cancelEvent(item)
        // Undo puts back a copy: same title, time, place, and notes. Invitations are not restored.
        if let start = item.start {
            let cal = calendar
            let end = item.end ?? start.addingTimeInterval(3600)
            await context.undo.push(.init(description: "cancelling “\(item.title)”") {
                try await cal.createEvent(title: item.title, start: start, end: end, location: item.location, notes: item.notes, allDay: item.isAllDay)
                return "Put “\(item.title)” back on the calendar."
            })
        }
        return ToolResult("Cancelled \(spokenEvent(item))." + (item.isRecurring ? " The rest of the series is unchanged." : ""),
                          summary: "Cancelled “\(item.title)”")
    }
}
