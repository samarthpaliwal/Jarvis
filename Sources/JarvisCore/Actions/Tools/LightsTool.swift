import Foundation

/// Tier 1: Govee lights. On, off, colour, brightness, warmth. Nothing else on the Govee account is touched.
public final class LightsTool: JarvisTool {
    public let name = "lights"
    public let description = "Control Sam's Govee lights: turn them on or off, set a colour, brightness (1-100), or white warmth in kelvin (2000 warm to 9000 cool). 'light' is part of a light's name (e.g. 'desk'); leave it out for every light. color is a plain colour name ('red', 'warm white', 'teal') or a hex like '#FF8800'. action 'list' names the lights."
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["on", "off", "color", "brightness", "temperature", "list"]],
            "light": ["type": "string", "description": "Part of the light's name. Omit for all lights."],
            "color": ["type": "string"],
            "brightness": ["type": "integer", "minimum": 1, "maximum": 100],
            "kelvin": ["type": "integer", "minimum": 2000, "maximum": 9000],
        ],
        "required": ["action"],
        "additionalProperties": false,
    ]
    private let govee: GoveeClient
    public init(govee: GoveeClient) { self.govee = govee }

    public func preview(for input: JSONObject) -> String { "Lights: \(input.string("action") ?? "?") \(input.string("light") ?? "all")" }

    /// Which lights a request means. No name: every light. A name: the lights whose name contains it.
    static func pick(_ all: [GoveeClient.Device], named query: String?) -> [GoveeClient.Device] {
        let lights = all.filter(\.isLight)
        guard let q = query?.lowercased().trimmingCharacters(in: .whitespaces), !q.isEmpty, !["all", "all lights", "lights", "the lights", "everything"].contains(q) else { return lights }
        let words = q.replacingOccurrences(of: "lights", with: "").replacingOccurrences(of: "light", with: "").trimmingCharacters(in: .whitespaces)
        return lights.filter { $0.name.lowercased().contains(q) || (!words.isEmpty && $0.name.lowercased().contains(words)) }
    }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let action = input.string("action") ?? ""
        let all: [GoveeClient.Device]
        do { all = try await govee.devices() } catch { return .error(error.localizedDescription) }
        let lights = all.filter(\.isLight)
        guard !lights.isEmpty else { return .error("Govee shows no lights on this account that its API can control.") }
        let names = lights.map(\.name).joined(separator: ", ")
        if action == "list" { return ToolResult("Lights: \(names).") }
        let targets = Self.pick(all, named: input.string("light"))
        guard !targets.isEmpty else { return .error("No light is called “\(input.string("light") ?? "")”. The lights are: \(names).") }

        let type: String, instance: String, value: Int, done: String
        switch action {
        case "on": (type, instance, value, done) = ("devices.capabilities.on_off", "powerSwitch", 1, "on")
        case "off": (type, instance, value, done) = ("devices.capabilities.on_off", "powerSwitch", 0, "off")
        case "color":
            guard let text = input.string("color"), let rgb = LightColor.parse(text) else { return .error("I don't know that colour. Give a plain colour name or a hex like #FF8800.") }
            (type, instance, value, done) = ("devices.capabilities.color_setting", "colorRgb", rgb, text.lowercased())
        case "brightness":
            guard let b = input.int("brightness") else { return .error("brightness is required (1-100).") }
            (type, instance, value, done) = ("devices.capabilities.range", "brightness", min(100, max(1, b)), "\(min(100, max(1, b)))%")
        case "temperature":
            guard let k = input.int("kelvin") else { return .error("kelvin is required (2000-9000).") }
            (type, instance, value, done) = ("devices.capabilities.color_setting", "colorTemperatureK", min(9000, max(2000, k)), "\(min(9000, max(2000, k)))K")
        default: return .error("Unknown action \(action).")
        }

        var changed: [String] = [], failed: [String] = []
        for light in targets {
            guard light.can.contains(instance) else { failed.append("\(light.name) can't do that"); continue }
            do {
                // A colour or brightness on a light that is off does nothing visible, so turn it on first.
                if action != "on", action != "off" { try? await govee.control(light, type: "devices.capabilities.on_off", instance: "powerSwitch", value: 1) }
                try await govee.control(light, type: type, instance: instance, value: value)
                changed.append(light.name)
            } catch { failed.append("\(light.name): \(error.localizedDescription)") }
        }
        guard !changed.isEmpty else { return .error("Nothing changed. \(failed.joined(separator: "; "))") }
        let what = changed.count == lights.count && changed.count > 1 ? "All lights" : changed.joined(separator: ", ")
        let line = "\(what) \(action == "on" || action == "off" ? "turned" : "set to") \(done)."
        return ToolResult(line + (failed.isEmpty ? "" : " Not changed: \(failed.joined(separator: "; "))."), summary: line)
    }
}
