import AppKit
import Foundation

/// Tier 1: open, switch to, hide, or quit one app by name. Denylisted apps are refused by the dispatcher.
public final class OpenAppTool: JarvisTool {
    public let name = "open_app"
    public let description = "Open or switch to an app by name (e.g. 'Safari', 'Notes', 'Spotify'). Can also hide or quit a single app. Quitting is reversible: the app can be reopened."
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": [
            "name": ["type": "string", "description": "App name as shown in Finder, without .app"],
            "action": ["type": "string", "enum": ["open", "hide", "quit"], "description": "Default open"],
        ],
        "required": ["name"],
        "additionalProperties": false,
    ]

    public init() {}

    public func targets(for input: JSONObject) -> ToolTargets {
        ToolTargets(apps: [input.string("name") ?? ""])
    }

    public func preview(for input: JSONObject) -> String {
        "\(input.string("action") ?? "open") \(input.string("name") ?? "?")"
    }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let appName = input.string("name"), !appName.isEmpty else { return .error("name is required") }
        let action = input.string("action") ?? "open"
        switch action {
        case "hide", "quit":
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame
            }) else { return ToolResult("\(appName) is not running.") }
            if action == "hide" { app.hide(); return ToolResult("Hid \(appName).", summary: "Hid \(appName)") }
            app.terminate()
            let url = app.bundleURL
            await context.undo.push(UndoStack.Entry(description: "quit \(appName)") {
                if let url { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
                return "Reopened \(appName)."
            })
            return ToolResult("Quit \(appName).", summary: "Quit \(appName)")
        default:
            guard let url = Self.findApp(named: appName) else { return .error("I couldn't find an app called \(appName).") }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            do {
                try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            } catch {
                return .error("Couldn't open \(appName): \(error.localizedDescription)")
            }
            return ToolResult("Opened \(appName).", summary: "Opened \(appName)")
        }
    }

    public static func findApp(named name: String) -> URL? {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     NSHomeDirectory() + "/Applications", "/Applications/Utilities"]
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            if let hit = items.first(where: { $0.lowercased() == wanted + ".app" }) ?? items.first(where: { $0.lowercased().hasPrefix(wanted) && $0.hasSuffix(".app") }) {
                return URL(fileURLWithPath: root).appendingPathComponent(hit)
            }
        }
        // Running apps know their own URL (covers apps installed elsewhere).
        return NSWorkspace.shared.runningApplications.first { $0.localizedName?.lowercased() == wanted }?.bundleURL
    }
}
