import Foundation

private let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE MMM d, h:mm a"; return f }()
private let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE MMM d"; return f }()

func describe(_ i: CalendarService.Item) -> String {
    var s = i.title
    if let st = i.start { s += " · " + (i.isAllDay ? dayFormatter.string(from: st) : timeFormatter.string(from: st)) }
    if let loc = i.location, !loc.isEmpty { s += " @ \(loc)" }
    return s
}

/// Tier 0: calendar events and reminders in a window.
public final class CalendarReadTool: JarvisTool {
    public let name = "calendar_read"
    public let description = "Read calendar events (all accounts in macOS Calendar, incl. Google) and incomplete reminders. Default: the next 24 hours. Use days (1–30) to look further ahead."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": [
            "days": ["type": "integer", "minimum": 1, "maximum": 30],
            "include_reminders": ["type": "boolean"],
        ],
        "additionalProperties": false,
    ]
    private let calendar: CalendarService
    public init(calendar: CalendarService) { self.calendar = calendar }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let days = input.int("days") ?? 1
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: now)!
        var lines = try await calendar.events(from: now, to: end).map { "Event: " + describe($0) }
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
    private let calendar: CalendarService
    public init(calendar: CalendarService) { self.calendar = calendar }

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
    private let calendar: CalendarService
    public init(calendar: CalendarService) { self.calendar = calendar }

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
