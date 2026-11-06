import Foundation

/// Finds a Spotify URI for "play Thunderstruck by AC/DC" using the Spotify Web API client-credentials
/// flow (a free developer app; no Spotify login needed). The URI is then played in the desktop app via AppleScript.
public final class SpotifySearch: @unchecked Sendable {
    public static let clientIDAccount = "SPOTIFY_CLIENT_ID"
    public static let clientSecretAccount = "SPOTIFY_CLIENT_SECRET"
    public struct Hit: Equatable, Sendable { public var uri: String; public var name: String; public var detail: String; public var kind: String }

    private var token: String?
    private var expires = Date.distantPast
    private let lock = NSLock()
    public init() {}

    public var isConfigured: Bool {
        KeychainStore.read(account: Self.clientIDAccount) != nil && KeychainStore.read(account: Self.clientSecretAccount) != nil
    }

    private func accessToken() async throws -> String {
        if let t = lock.withLock({ expires > Date() ? token : nil }) { return t }
        guard let id = KeychainStore.read(account: Self.clientIDAccount), let secret = KeychainStore.read(account: Self.clientSecretAccount) else {
            throw NSError(domain: "Jarvis.Spotify", code: 1, userInfo: [NSLocalizedDescriptionKey: "Spotify search isn't set up."])
        }
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("Basic " + Data("\(id):\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("grant_type=client_credentials".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? JSONObject) ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let t = obj["access_token"] as? String else {
            throw NSError(domain: "Jarvis.Spotify", code: 2, userInfo: [NSLocalizedDescriptionKey: "Spotify rejected the client ID/secret."])
        }
        lock.withLock { token = t; expires = Date().addingTimeInterval(TimeInterval((obj["expires_in"] as? Int ?? 3600) - 60)) }
        return t
    }

    /// `kind`: track, artist, album, playlist.
    public func search(_ query: String, kind: String) async throws -> Hit? {
        let t = try await accessToken()
        let type = ["track", "artist", "album", "playlist"].contains(kind) ? kind : "track"
        var c = URLComponents(string: "https://api.spotify.com/v1/search")!
        c.queryItems = [.init(name: "q", value: query), .init(name: "type", value: type), .init(name: "limit", value: "1")]
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? JSONObject) ?? [:]
        return Self.parse(obj, kind: type)
    }

    static func parse(_ obj: JSONObject, kind: String) -> Hit? {
        guard let items = (obj["\(kind)s"] as? JSONObject)?["items"] as? [Any],
              let item = items.compactMap({ $0 as? JSONObject }).first, let uri = item["uri"] as? String else { return nil }
        let name = item["name"] as? String ?? ""
        var detail = ""
        if let artists = item["artists"] as? [JSONObject] { detail = artists.compactMap { $0["name"] as? String }.joined(separator: ", ") }
        if kind == "playlist" { detail = ((item["owner"] as? JSONObject)?["display_name"] as? String) ?? "" }
        return Hit(uri: uri, name: name, detail: detail, kind: kind)
    }
}
