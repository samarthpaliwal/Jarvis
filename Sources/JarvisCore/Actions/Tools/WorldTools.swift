import Foundation

/// Tier 0: weather for the profile city or any named city.
public final class WeatherTool: JarvisTool {
    public let name = "weather"
    public let description = "Current weather and today's high/low/rain chance. Defaults to Sam's home city; pass city for elsewhere (e.g. 'Singapore')."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = ["type": "object", "properties": ["city": ["type": "string"]], "additionalProperties": false]
    private let world: WorldService
    public init(world: WorldService) { self.world = world }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let profile = await context.config.profile
        let city = input.string("city") ?? profile.world?.weatherCity ?? profile.city
        let w = try await world.weather(city: city, unit: profile.world?.units ?? "celsius")
        return ToolResult("\(w.city): \(Int(w.temperature.rounded()))\(w.unit) (feels \(Int(w.feelsLike.rounded()))), \(w.condition). High \(Int(w.high.rounded())), low \(Int(w.low.rounded())), rain \(w.rainChance)%.",
                          card: .info(title: "Weather · \(w.city)", lines: ["\(Int(w.temperature.rounded()))\(w.unit) · \(w.condition)", "H \(Int(w.high.rounded())) · L \(Int(w.low.rounded())) · rain \(w.rainChance)%"]))
    }
}

/// Tier 0: top tech headlines (Hacker News).
public final class NewsHeadlinesTool: JarvisTool {
    public let name = "news_headlines"
    public let description = "Top tech headlines right now (Hacker News front page)."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = ["type": "object", "properties": ["limit": ["type": "integer", "minimum": 1, "maximum": 10]], "additionalProperties": false]
    private let world: WorldService
    public init(world: WorldService) { self.world = world }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let titles = try await world.headlines(limit: input.int("limit") ?? 5)
        if titles.isEmpty { return ToolResult("No headlines right now.") }
        return ToolResult(Untrusted.wrap(titles.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"), source: "hackernews"),
                          card: .info(title: "Headlines", lines: Array(titles.prefix(5))))
    }
}
