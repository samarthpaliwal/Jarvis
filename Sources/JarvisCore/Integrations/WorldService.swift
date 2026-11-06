import Foundation

/// Weather and headlines for the briefing (OpenJarvis's "world" digest section).
/// Weather uses Open-Meteo (no API key). Only the city NAME from profile.json is sent, never GPS coordinates.
public final class WorldService: @unchecked Sendable {
    public struct Weather: Equatable, Sendable {
        public var city: String
        public var temperature: Double
        public var feelsLike: Double
        public var high: Double
        public var low: Double
        public var rainChance: Int
        public var condition: String
        public var unit: String
        public var spoken: String {
            "\(Int(temperature.rounded()))° and \(condition.lowercased()) in \(city), high of \(Int(high.rounded())), low \(Int(low.rounded()))" +
            (rainChance >= 30 ? ", \(rainChance) percent chance of rain" : "")
        }
    }

    private let session: URLSession
    private var geoCache: [String: (Double, Double, String)] = [:]
    private let lock = NSLock()
    public init(session: URLSession = .shared) { self.session = session }

    public func weather(city: String, unit: String = "celsius") async throws -> Weather {
        let (lat, lon, name) = try await geocode(city)
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", lat)), .init(name: "longitude", value: String(format: "%.3f", lon)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "1"),
            .init(name: "temperature_unit", value: unit == "fahrenheit" ? "fahrenheit" : "celsius"),
        ]
        let obj = try await json(c.url!)
        let cur = obj["current"] as? JSONObject ?? [:]
        let daily = obj["daily"] as? JSONObject ?? [:]
        func first(_ k: String) -> Double { ((daily[k] as? [Any])?.first as? NSNumber)?.doubleValue ?? 0 }
        return Weather(city: name, temperature: (cur["temperature_2m"] as? NSNumber)?.doubleValue ?? 0,
                       feelsLike: (cur["apparent_temperature"] as? NSNumber)?.doubleValue ?? 0,
                       high: first("temperature_2m_max"), low: first("temperature_2m_min"),
                       rainChance: Int(first("precipitation_probability_max")),
                       condition: Self.condition((cur["weather_code"] as? NSNumber)?.intValue ?? -1), unit: unit == "fahrenheit" ? "°F" : "°C")
    }

    /// Top Hacker News stories (no key needed).
    public func headlines(limit: Int = 3) async throws -> [String] {
        guard let ids = try await jsonArray(URL(string: "https://hacker-news.firebaseio.com/v0/topstories.json")!) as? [Int] else { return [] }
        var titles: [String] = []
        for id in ids.prefix(limit) {
            if let item = try? await json(URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json")!), let t = item["title"] as? String {
                titles.append(t)
            }
        }
        return titles
    }

    private func geocode(_ city: String) async throws -> (Double, Double, String) {
        if let hit = lock.withLock({ geoCache[city.lowercased()] }) { return hit }
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1"), .init(name: "language", value: "en")]
        let obj = try await json(c.url!)
        guard let r = (obj["results"] as? [JSONObject])?.first, let lat = (r["latitude"] as? NSNumber)?.doubleValue,
              let lon = (r["longitude"] as? NSNumber)?.doubleValue else {
            throw NSError(domain: "Jarvis.Weather", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't find a place called \(city)."])
        }
        let hit = (lat, lon, r["name"] as? String ?? city)
        lock.withLock { geoCache[city.lowercased()] = hit }
        return hit
    }

    private func json(_ url: URL) async throws -> JSONObject {
        (try await jsonArray(url) as? JSONObject) ?? [:]
    }

    private func jsonArray(_ url: URL) async throws -> Any {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Jarvis.World", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(url.host ?? "service") returned an error."])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// WMO weather codes → words.
    public static func condition(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Foggy"
        case 51, 53, 55, 56, 57: return "Drizzle"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "Rain"
        case 71, 73, 75, 77, 85, 86: return "Snow"
        case 95, 96, 99: return "Thunderstorms"
        default: return "Unsettled"
        }
    }
}
