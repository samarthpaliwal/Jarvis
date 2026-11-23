import AppKit
import Foundation

/// Tier 1: control Spotify (default) or Apple Music through AppleScript. Replaces the old media-key
/// approach, which macOS silently ignores without Accessibility permission.
public final class MusicTool: JarvisTool {
    public let name = "music"
    public let description = """
    Control music in Spotify (default) or Apple Music. Actions: play (resume), pause, toggle, next, previous, now_playing, \
    play_query (play a song/artist/album/playlist by name: give query and kind), volume (percent, the app's own volume), \
    shuffle (on true/false). Use play_query for "play Thunderstruck by AC/DC", "play some Drake", "play my workout playlist".
    """
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["play", "pause", "toggle", "next", "previous", "now_playing", "play_query", "volume", "shuffle"]],
            "query": ["type": "string", "description": "for play_query, e.g. 'Thunderstruck AC/DC'"],
            "kind": ["type": "string", "enum": ["track", "artist", "album", "playlist"], "description": "for play_query; default track"],
            "percent": ["type": "integer", "minimum": 0, "maximum": 100],
            "on": ["type": "boolean"],
            "app": ["type": "string", "enum": ["spotify", "music"], "description": "default spotify"],
        ],
        "required": ["action"], "additionalProperties": false,
    ]
    private let spotify: SpotifySearch
    public init(spotify: SpotifySearch) { self.spotify = spotify }

    public func targets(for input: JSONObject) -> ToolTargets { ToolTargets(apps: [input.string("app") == "music" ? "Music" : "Spotify"]) }
    public func preview(for input: JSONObject) -> String { "music \(input.string("action") ?? "") \(input.string("query") ?? "")" }

    static var spotifyInstalled: Bool { OpenAppTool.findApp(named: "Spotify") != nil }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let action = input.string("action") ?? "toggle"
        let useMusic = input.string("app") == "music" || !Self.spotifyInstalled
        let app = useMusic ? "Music" : "Spotify"
        let tell = "tell application \"\(app)\" to "
        switch action {
        case "play":     _ = try await script(tell + "play"); return await nowPlaying(app, prefix: "Playing")
        case "pause":    _ = try await script(tell + "pause"); return ToolResult("Paused \(app).", summary: "Paused")
        case "toggle":   _ = try await script(tell + "playpause"); return ToolResult("Toggled \(app).", summary: "Play/pause")
        case "next":     _ = try await script(tell + (useMusic ? "next track" : "next track")); try? await Task.sleep(for: .milliseconds(400)); return await nowPlaying(app, prefix: "Skipped. Now")
        case "previous": _ = try await script(tell + "previous track"); try? await Task.sleep(for: .milliseconds(400)); return await nowPlaying(app, prefix: "Back to")
        case "now_playing": return await nowPlaying(app, prefix: "Now playing")
        case "volume":
            guard let p = input.int("percent") else { return .error("percent is required") }
            _ = try await script(tell + "set sound volume to \(max(0, min(100, p)))")
            return ToolResult("\(app) volume \(p)%.", summary: "\(app) volume \(p)%")
        case "shuffle":
            let on = input.bool("on") ?? true
            _ = try await script(useMusic ? "tell application \"Music\" to set shuffle enabled to \(on)" : tell + "set shuffling to \(on)")
            return ToolResult("Shuffle \(on ? "on" : "off").", summary: "Shuffle \(on ? "on" : "off")")
        case "play_query":
            guard let q = input.string("query"), !q.isEmpty else { return .error("query is required") }
            return try await playQuery(q, kind: input.string("kind") ?? "track", useMusic: useMusic)
        default:
            return .error("Unknown action \(action)")
        }
    }

    private func playQuery(_ q: String, kind: String, useMusic: Bool) async throws -> ToolResult {
        if useMusic {
            let s = AppleScriptRunner.quote(q)
            let src = """
            tell application "Music"
              set hits to (every track of library playlist 1 whose name contains \(s) or artist contains \(s) or album contains \(s))
              if (count of hits) is 0 then return ""
              play item 1 of hits
              return (name of item 1 of hits) & " by " & (artist of item 1 of hits)
            end tell
            """
            let r = try await script(src)
            return r.isEmpty ? .error("Nothing in your Music library matches “\(q)”.") : ToolResult("Playing \(r).", summary: "Playing \(r)")
        }
        guard spotify.isConfigured else {
            // Without search credentials, open Spotify's own search so one tap plays it.
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q
            if let url = URL(string: "spotify:search:\(encoded)") { _ = await MainActor.run { NSWorkspace.shared.open(url) } }
            return ToolResult("Opened Spotify search for “\(q)”. Spotify search isn't set up yet, so Sam has to press play once; tell him he can enable one-step playback from the Jarvis menu (Integrations → Set Spotify Client…).",
                              summary: "Spotify search: \(q)")
        }
        var found = try await spotify.search(q, kind: kind)
        if found == nil, kind == "track" { found = try await spotify.search(q, kind: "artist") }
        guard let hit = found else { return .error("Spotify found nothing for “\(q)”.") }
        _ = try await script("tell application \"Spotify\" to play track \(AppleScriptRunner.quote(hit.uri))")
        let label = hit.detail.isEmpty ? hit.name : "\(hit.name) by \(hit.detail)"
        return ToolResult("Playing \(label) on Spotify.", summary: "Playing \(label)")
    }

    private func nowPlaying(_ app: String, prefix: String) async -> ToolResult {
        let src = "tell application \"\(app)\" to if player state is playing then return (name of current track) & \" by \" & (artist of current track)"
        let r = (try? await script(src)) ?? ""
        return ToolResult(r.isEmpty ? "\(app) isn't playing anything." : "\(prefix): \(r).", summary: r.isEmpty ? nil : "\(prefix): \(r)")
    }

    private func script(_ src: String) async throws -> String {
        try await MainActor.run { try AppleScriptRunner.run(src) }
    }
}
