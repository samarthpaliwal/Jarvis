import Foundation

/// Govee lights through Govee's own cloud API (developer.govee.com). The key comes from the Govee Home app
/// (Profile → Settings → Apply for API Key) and lives in the Keychain as GOVEE_API_KEY.
public final class GoveeClient: @unchecked Sendable {
    public struct Device: Equatable, Sendable {
        public var sku: String
        public var id: String
        public var name: String
        /// Capability instances the device reports: powerSwitch, brightness, colorRgb, colorTemperatureK…
        public var can: Set<String>
        public var isLight: Bool { can.contains("powerSwitch") && (can.contains("colorRgb") || can.contains("brightness")) }
    }

    public enum GoveeError: LocalizedError, Equatable {
        case noKey, http(Int, String), malformed
        public var errorDescription: String? {
            switch self {
            case .noKey: return "Govee isn't connected. Use Integrations → Connect Govee Lights… in the Jarvis menu."
            case .http(401, _), .http(403, _): return "Govee refused the API key. Set it again in the Jarvis menu."
            case .http(429, _): return "Govee says too many requests. Try again in a minute."
            case .http(let c, let m): return "Govee error \(c): \(m)"
            case .malformed: return "Unexpected Govee response."
            }
        }
    }

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    public static let keyAccount = "GOVEE_API_KEY"
    static let base = "https://openapi.api.govee.com/router/api/v1"

    private let key: @Sendable () -> String?
    private let transport: Transport
    private let lock = NSLock()
    private var cache: (at: Date, devices: [Device])?

    public init(key: @escaping @Sendable () -> String? = { KeychainStore.read(account: GoveeClient.keyAccount) },
                transport: @escaping Transport = { req in
                    let (data, response) = try await URLSession.shared.data(for: req)
                    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
                }) {
        self.key = key; self.transport = transport
    }

    public var isConfigured: Bool { key() != nil }

    private func send(_ path: String, body: JSONObject? = nil) async throws -> JSONObject {
        guard let key = key() else { throw GoveeError.noKey }
        var req = URLRequest(url: URL(string: Self.base + path)!)
        req.httpMethod = body == nil ? "GET" : "POST"
        req.timeoutInterval = 10
        req.setValue(key, forHTTPHeaderField: "Govee-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, status) = try await transport(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
        let code = json?.int("code") ?? status
        guard status == 200, code == 200 else {
            throw GoveeError.http(status == 200 ? code : status, String((json?.string("message") ?? json?.string("msg") ?? "").prefix(120)))
        }
        guard let json else { throw GoveeError.malformed }
        return json
    }

    static func parseDevices(_ json: JSONObject) -> [Device] {
        (json["data"] as? [JSONObject] ?? []).compactMap { d in
            guard let sku = d.string("sku"), let id = d.string("device") else { return nil }
            let caps = (d["capabilities"] as? [JSONObject] ?? []).compactMap { $0.string("instance") }
            let name = d.string("deviceName").flatMap { $0.isEmpty ? nil : $0 } ?? sku
            return Device(sku: sku, id: id, name: name, can: Set(caps))
        }
    }

    /// The account's devices. Kept for ten minutes: the list rarely changes and Govee limits requests.
    public func devices(refresh: Bool = false, now: Date = Date()) async throws -> [Device] {
        if !refresh, let c = lock.withLock({ cache }), now.timeIntervalSince(c.at) < 600 { return c.devices }
        let list = Self.parseDevices(try await send("/user/devices"))
        lock.withLock { cache = (now, list) }
        return list
    }

    public func control(_ device: Device, type: String, instance: String, value: Int) async throws {
        _ = try await send("/device/control", body: [
            "requestId": UUID().uuidString,
            "payload": ["sku": device.sku, "device": device.id,
                        "capability": ["type": type, "instance": instance, "value": value] as JSONObject] as JSONObject,
        ])
    }
}

/// Colours by name or hex, as one number the way Govee wants it (0xRRGGBB).
public enum LightColor {
    static let named: [String: Int] = [
        "red": 0xFF0000, "green": 0x00FF00, "blue": 0x0000FF, "white": 0xFFFFFF, "yellow": 0xFFFF00, "orange": 0xFF6A00,
        "purple": 0x8000FF, "violet": 0x8000FF, "pink": 0xFF3FA4, "hot pink": 0xFF1493, "magenta": 0xFF00FF, "cyan": 0x00FFFF,
        "teal": 0x00B3A4, "turquoise": 0x30D5C8, "aqua": 0x00FFFF, "lime": 0xBFFF00, "amber": 0xFFBF00, "gold": 0xFFC400,
        "warm white": 0xFFD6A5, "cool white": 0xE6F0FF, "lavender": 0xB57EDC, "indigo": 0x4B0082, "crimson": 0xDC143C,
        "coral": 0xFF7F50, "peach": 0xFFCBA4, "mint": 0x98FF98, "sky blue": 0x87CEEB, "navy": 0x000080, "maroon": 0x800000,
        "light blue": 0x66CCFF, "dark blue": 0x0000A0, "light green": 0x90EE90, "rose": 0xFF007F,
    ]

    public static func parse(_ text: String) -> Int? {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = named[t] { return n }
        let hex = t.hasPrefix("#") ? String(t.dropFirst()) : t.hasPrefix("0x") ? String(t.dropFirst(2)) : t
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return Int(hex, radix: 16)
    }
}
