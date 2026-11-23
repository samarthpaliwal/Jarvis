import Foundation

/// Tier 1: screen brightness (built-in display). Undoable.
public final class SetBrightnessTool: JarvisTool {
    public let name = "set_brightness"
    public let description = "Set the built-in display brightness 0–100. Reversible."
    public let tier = Tier.free
    public let inputSchema: JSONObject = ["type": "object", "properties": ["percent": ["type": "integer", "minimum": 0, "maximum": 100]],
                                          "required": ["percent"], "additionalProperties": false]
    public init() {}
    public func preview(for input: JSONObject) -> String { "brightness \(input.int("percent") ?? 0)%" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let pct = input.int("percent") else { return .error("percent is required") }
        guard let before = Brightness.current() else { return .error("Brightness control isn't available on this display.") }
        guard Brightness.set(Float(pct) / 100) else { return .error("Couldn't change brightness.") }
        await context.undo.push(.init(description: "brightness \(pct)%") { Brightness.set(before); return "Brightness back to \(Int(before * 100))%." })
        return ToolResult("Brightness set to \(pct)%.", summary: "Brightness \(pct)%")
    }
}

/// Tier 1: macOS Focus via the Shortcuts app. macOS has no public API, so Jarvis runs a shortcut
/// named "Jarvis Focus: <name>" (and "Jarvis Focus Off") that you create once with a Set Focus action.
public final class SetFocusTool: JarvisTool {
    public let name = "set_focus"
    public let description = "Turn a macOS Focus on ('Do Not Disturb', 'Work', 'Study'…) or off. Runs the Shortcut named 'Jarvis Focus: <name>' / 'Jarvis Focus Off'."
    public let tier = Tier.free
    public let inputSchema: JSONObject = ["type": "object", "properties": ["focus": ["type": "string", "description": "Focus name, or 'off'"]],
                                          "required": ["focus"], "additionalProperties": false]
    public init() {}
    public func preview(for input: JSONObject) -> String { "focus \(input.string("focus") ?? "")" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let focus = input.string("focus") else { return .error("focus is required") }
        let shortcut = focus.lowercased() == "off" ? "Jarvis Focus Off" : "Jarvis Focus: \(focus)"
        let out = await Sandbox.run("/usr/bin/shortcuts run \"\(shortcut.replacingOccurrences(of: "\"", with: ""))\"", timeout: 15)
        guard out.exitCode == 0 else {
            return .error("No Shortcut named “\(shortcut)”. Create it in Shortcuts with a “Set Focus” action (see README).")
        }
        if focus.lowercased() != "off" {
            await context.undo.push(.init(description: "focus \(focus)") {
                _ = await Sandbox.run("/usr/bin/shortcuts run \"Jarvis Focus Off\"", timeout: 15); return "Focus turned off."
            })
        }
        return ToolResult("Focus \(focus.lowercased() == "off" ? "off" : "set to \(focus)").", summary: "Focus: \(focus)")
    }
}

/// Tier 1: "Jarvis, remember this place as the gym". Writes to modes.json.
public final class RememberPlaceTool: JarvisTool {
    public let name = "remember_place"
    public let description = "Save the current location and Wi-Fi as a named place (e.g. 'gym', 'Honors Village') in modes.json, optionally attached to a mode's triggers."
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": ["name": ["type": "string"], "mode": ["type": "string", "description": "optional mode id to trigger here"],
                       "radius_meters": ["type": "integer", "minimum": 50, "maximum": 5000]],
        "required": ["name"], "additionalProperties": false,
    ]
    private let detector: ContextDetector
    public init(detector: ContextDetector) { self.detector = detector }
    public func preview(for input: JSONObject) -> String { "remember place “\(input.string("name") ?? "")”" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let name = input.string("name"), !name.isEmpty else { return .error("name is required") }
        let coords = await detector.currentCoordinates()
        let ssid = ContextDetector.currentSSID()
        guard coords != nil || ssid != nil else { return .error("I can't tell where we are: no location permission and no Wi-Fi name.") }
        let id = name.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
        var config = await context.config.modes
        config.places.removeAll { $0.id == id }
        config.places.append(Place(id: id, name: name, latitude: coords?.0, longitude: coords?.1,
                                   radiusMeters: Double(input.int("radius_meters") ?? 150), wifiSSIDs: ssid.map { [$0] } ?? []))
        if let modeID = input.string("mode"), let idx = config.modes.firstIndex(where: { $0.id == modeID }) {
            if !config.modes[idx].triggers.places.contains(id) { config.modes[idx].triggers.places.append(id) }
        }
        try await context.config.save(modes: config)
        return ToolResult("Saved “\(name)”\(coords == nil ? " by Wi-Fi only" : "").", summary: "Remembered place “\(name)”")
    }
}
