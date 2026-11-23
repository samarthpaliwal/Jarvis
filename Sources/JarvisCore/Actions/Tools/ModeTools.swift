import AppKit
import Foundation

/// Tier 0: what mode Jarvis is in and the signals behind it.
public final class GetLocationContextTool: JarvisTool {
    public let name = "get_location_context"
    public let description = "Current Jarvis mode (Home/Class/Study/Work/Road), how it was chosen, power state, displays, and the known places. Never returns coordinates."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = ["type": "object", "properties": [:], "additionalProperties": false]

    public init() {}

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let mode = await context.modes.current
        let b = SystemInfo.battery()
        let places = await context.config.modes.places.map(\.name).joined(separator: ", ")
        let lines = [
            "Mode: \(mode.name) (\(mode.id)), voice \(mode.voice.enabled ? "on" : "off")",
            "Power: \(b.onBattery ? "battery" : "plugged in")\(b.percent.map { " \($0)%" } ?? "")",
            "Displays: \(NSScreen.screens.count)",
            "Known places: \(places)",
            "Available modes: " + (await context.modes.available.map(\.id).joined(separator: ", ")),
        ]
        return ToolResult(lines.joined(separator: "\n"))
    }
}

/// Tier 1: switch modes by voice ("Jarvis, class mode").
public final class SetModeTool: JarvisTool {
    public let name = "set_mode"
    public let description = "Switch Jarvis to a mode: home, class, study, work, or road."
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": ["mode": ["type": "string", "description": "mode id, e.g. class"]],
        "required": ["mode"],
        "additionalProperties": false,
    ]

    public init() {}

    public func preview(for input: JSONObject) -> String { "switch to \(input.string("mode") ?? "?") mode" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let id = input.string("mode")?.lowercased() else { return .error("mode is required") }
        let modes = context.modes
        guard let target = await modes.available.first(where: { $0.id == id || $0.name.lowercased() == id }) else {
            let ids = await modes.available.map(\.id).joined(separator: ", ")
            return .error("Unknown mode \(id). Available: \(ids)")
        }
        let previous = await modes.current
        await modes.switchTo(id: target.id, reason: "voice")
        await context.undo.push(.init(description: "switch to \(target.name) mode") {
            await modes.switchTo(id: previous.id, reason: "undo"); return "Back in \(previous.name) mode."
        })
        return ToolResult("Switched to \(target.name) mode.", summary: "\(target.name) mode")
    }
}

/// Tier 1: "Jarvis, undo that".
public final class UndoLastActionTool: JarvisTool {
    public let name = "undo_last_action"
    public let description = "Undo the most recent reversible thing Jarvis did (file moves, volume, mode, timers, quit apps)."
    public let tier = Tier.free
    public let inputSchema: JSONObject = ["type": "object", "properties": [:], "additionalProperties": false]

    public init() {}

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard await context.undo.canUndo else { return ToolResult("Nothing to undo.") }
        let what = await context.undo.lastDescription ?? ""
        let msg = try await context.undo.undoLast()
        return ToolResult(msg, summary: "Undid: \(what)")
    }
}

/// Tier 0: "what did you do today".
public final class ActionsTodayTool: JarvisTool {
    public let name = "actions_today"
    public let description = "List every tool call Jarvis made today with time and outcome, from the action log."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = ["type": "object", "properties": [:], "additionalProperties": false]
    private let log: ActionLog

    public init(log: ActionLog) { self.log = log }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let lines = log.todaySummary().filter { !$0.contains("actions_today") }
        if lines.isEmpty { return ToolResult("Nothing yet today.") }
        return ToolResult(lines.joined(separator: "\n"), card: .info(title: "Today", lines: Array(lines.suffix(6))))
    }
}
