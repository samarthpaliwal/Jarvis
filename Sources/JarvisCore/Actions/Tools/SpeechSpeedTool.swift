import Foundation

/// Tier 1: how fast Jarvis talks. "Talk faster" and "talk slower" move it one step and save it.
public final class SpeechSpeedTool: JarvisTool {
    public let name = "speech_speed"
    public let description = "Change how fast you (Jarvis) talk, and save it. Use when Sam says talk faster, talk slower, speed up, slow down, you talk too fast or too slow, or asks for normal speed. action: 'faster' or 'slower' (one step, 10%), 'set' with speed (1.0 = natural pace, 1.3 = 30% faster; 0.7 to 2.0), 'reset' (back to the default), or 'status'."
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["faster", "slower", "set", "reset", "status"]],
            "speed": ["type": "number", "minimum": 0.7, "maximum": 2.0, "description": "Only with action set"],
        ],
        "required": ["action"],
        "additionalProperties": false,
    ]

    private let read: @MainActor () -> Double
    private let save: @MainActor (Double) throws -> Void

    public init(read: @escaping @MainActor () -> Double, save: @escaping @MainActor (Double) throws -> Void) {
        self.read = read; self.save = save
    }

    public func preview(for input: JSONObject) -> String { "talk \(input.string("action") ?? "faster")" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let before = await read()
        let target: Double
        switch input.string("action") ?? "" {
        case "faster": target = SpeechPace.nudged(before, faster: true)
        case "slower": target = SpeechPace.nudged(before, faster: false)
        case "reset": target = SpeechPace.defaultSpeed
        case "set":
            guard let s = input.double("speed") else { return .error("Give a speed between 0.7 and 2.0.") }
            target = SpeechPace.clamp(s)
        case "status": return ToolResult("Speaking at \(SpeechPace.spoken(before)) (\(before)).", summary: "Speech speed \(before)")
        default: return .error("action must be faster, slower, set, reset or status.")
        }
        if target == before {
            let edge = target >= SpeechPace.range.upperBound ? "the fastest" : target <= SpeechPace.range.lowerBound ? "the slowest" : "that speed"
            return ToolResult("Already at \(edge) (\(before)). Nothing changed.", summary: "Speech speed unchanged")
        }
        do { try await save(target) } catch { return .error("I couldn't save the new speed: \(error.localizedDescription)") }
        await context.undo.push(.init(description: "speech speed to \(target)") { [save] in
            try await save(before); return "Speech speed back to \(before)."
        })
        return ToolResult("Now speaking at \(SpeechPace.spoken(target)) (\(target)), saved. Your next sentence is already at the new speed; keep the reply to a few words.",
                          summary: "Speech speed \(target)")
    }
}
