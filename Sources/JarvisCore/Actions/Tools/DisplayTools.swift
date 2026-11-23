import Foundation

/// Tier 1: "Jarvis, full screen" / "back to the notch".
public final class SetDisplayModeTool: JarvisTool {
    public let name = "set_display_mode"
    public let description = "Switch Jarvis between the notch UI and the full-screen HUD ('full screen', 'hud', 'notch'). 'always' keeps the HUD for every conversation."
    public let tier = Tier.free
    public let inputSchema: JSONObject = ["type": "object", "properties": ["mode": ["type": "string", "enum": ["hud", "notch", "always_hud", "always_notch"]]],
                                          "required": ["mode"], "additionalProperties": false]
    private let hud: HUDWindowController
    public init(hud: HUDWindowController) { self.hud = hud }
    public func preview(for input: JSONObject) -> String { "display \(input.string("mode") ?? "")" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        switch input.string("mode") {
        case "hud": await hud.show(scene: false); return ToolResult("HUD up.", summary: "Full-screen HUD")
        case "notch": await hud.dismiss(reason: "tool"); return ToolResult("Back to the notch.", summary: "Notch mode")
        case "always_hud": await MainActor.run { hud.fullScreenAlways = true; hud.show(scene: false) }; return ToolResult("Full screen for every conversation.", summary: "HUD always on")
        case "always_notch": await MainActor.run { hud.fullScreenAlways = false }; await hud.dismiss(reason: "tool"); return ToolResult("Notch only from now on.", summary: "HUD always off")
        default: return .error("mode must be hud, notch, always_hud or always_notch")
        }
    }
}

/// Tier 1: "I'm home" by voice runs the homecoming scene.
public final class WelcomeHomeTool: JarvisTool {
    public let name = "welcome_home"
    public let description = "Run the homecoming sequence (HUD, welcome, Home mode, today's status). Use when Sam says he's home, just got back, or 'wake up'."
    public let tier = Tier.free
    public let inputSchema: JSONObject = ["type": "object", "properties": [:], "additionalProperties": false]
    private let run: @MainActor () -> Void
    public init(run: @escaping @MainActor () -> Void) { self.run = run }
    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        await run()
        return ToolResult("Homecoming running; keep your reply to a short acknowledgement, the scene speaks for itself.", summary: "Welcome home")
    }
}
