import Foundation

/// Tier 0: the daily briefing.
public final class GetBriefingTool: JarvisTool {
    public let name = "get_briefing"
    public let description = "Today's remaining tasks and events, the next deadlines, exams in the next 14 days with days left, and recent assignment/exam emails. Use for 'what's left today', 'what's due', 'morning briefing', 'any exams coming up'."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = ["type": "object", "properties": [:], "additionalProperties": false]
    private let service: BriefingService
    public init(service: BriefingService) { self.service = service }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let mode = await context.modes.current
        let r = await service.build(mode: mode)
        func fmt(_ i: BriefingData.Item) -> String {
            var s = i.title
            if let d = i.detail { s += " (\(d))" }
            if let days = i.daysLeft { s += " — \(days == 0 ? "today" : "\(days) day\(days == 1 ? "" : "s") left")" }
            return s
        }
        var text = "Today: " + (r.data.tasks.isEmpty ? "nothing left" : r.data.tasks.map(fmt).joined(separator: "; "))
        text += "\nDeadlines: " + (r.data.deadlines.isEmpty ? "none" : r.data.deadlines.map(fmt).joined(separator: "; "))
        text += "\nExams (next 14 days): " + (r.data.exams.isEmpty ? "none" : r.data.exams.map(fmt).joined(separator: "; "))
        if let c = r.nextClass { text += "\nNext class: \(fmt(c))" }
        if !r.notes.isEmpty { text += "\nSources unavailable: " + r.notes.joined(separator: "; ") }
        text += "\nSuggested spoken summary: \(r.spoken)"
        return ToolResult(Untrusted.wrap(text, source: "briefing"), card: .briefing(r.data))
    }
}
