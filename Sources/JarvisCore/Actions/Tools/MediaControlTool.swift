import AppKit
import Foundation

/// Tier 1: play/pause/next/previous via the system media keys (works for Music, Spotify, browsers).
public final class MediaControlTool: JarvisTool {
    public let name = "media_control"
    public let description = "Control whatever is playing: play, pause, toggle, next, previous."
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": ["action": ["type": "string", "enum": ["play", "pause", "toggle", "next", "previous"]]],
        "required": ["action"],
        "additionalProperties": false,
    ]

    public init() {}

    public func preview(for input: JSONObject) -> String { "media \(input.string("action") ?? "?")" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let action = input.string("action") ?? "toggle"
        let key: Int32
        switch action {
        case "next": key = NX_KEYTYPE_NEXT
        case "previous": key = NX_KEYTYPE_PREVIOUS
        default: key = NX_KEYTYPE_PLAY
        }
        Self.pressMediaKey(key)
        return ToolResult("Sent \(action).", summary: "Media: \(action)")
    }

    static func pressMediaKey(_ key: Int32) {
        func post(_ down: Bool) {
            let flags: NSEvent.ModifierFlags = down ? NSEvent.ModifierFlags(rawValue: 0xA00) : NSEvent.ModifierFlags(rawValue: 0xB00)
            let data1 = Int((key << 16) | (down ? 0xA << 8 : 0xB << 8))
            guard let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                              windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1) else { return }
            ev.cgEvent?.post(tap: .cghidEventTap)
        }
        post(true)
        post(false)
    }
}
