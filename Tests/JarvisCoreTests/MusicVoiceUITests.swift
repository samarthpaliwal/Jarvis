import XCTest
@testable import JarvisCore

final class MusicTests: XCTestCase {
    func testAppleScriptQuoting() {
        XCTAssertEqual(AppleScriptRunner.quote("AC/DC \"Thunderstruck\""), "\"AC/DC \\\"Thunderstruck\\\"\"")
        XCTAssertEqual(AppleScriptRunner.quote("a\\b"), "\"a\\\\b\"")
    }

    func testSpotifySearchParsing() {
        let obj: JSONObject = ["tracks": ["items": [["uri": "spotify:track:57bgtoPSgt236HzfBOd8kj", "name": "Thunderstruck",
                                                      "artists": [["name": "AC/DC"]]]]]]
        let hit = SpotifySearch.parse(obj, kind: "track")
        XCTAssertEqual(hit?.uri, "spotify:track:57bgtoPSgt236HzfBOd8kj")
        XCTAssertEqual(hit?.detail, "AC/DC")
        XCTAssertNil(SpotifySearch.parse(["tracks": ["items": []]], kind: "track"))
        let pl: JSONObject = ["playlists": ["items": [NSNull(), ["uri": "spotify:playlist:x", "name": "Gym", "owner": ["display_name": "Sam"]]]]]
        XCTAssertEqual(SpotifySearch.parse(pl, kind: "playlist")?.uri, "spotify:playlist:x", "skips null items Spotify sometimes returns")
    }
}

final class VoiceTests: XCTestCase {
    func testSiriNeuralRanksAbovePremium() {
        let siri = VoicePicker.Candidate(identifier: "com.apple.siri.natural.en-GB-M", name: "Voice 2", language: "en-GB", quality: .enhanced)
        let premium = VoicePicker.Candidate(identifier: "com.apple.voice.premium.en-GB.Jamie", name: "Jamie", language: "en-GB", quality: .premium)
        let daniel = VoicePicker.Candidate(identifier: "com.apple.voice.compact.en-GB.Daniel", name: "Daniel", language: "en-GB", quality: .default)
        let novelty = VoicePicker.Candidate(identifier: "com.apple.speech.synthesis.voice.Albert", name: "Albert", language: "en-US", quality: .default)
        XCTAssertGreaterThan(VoicePicker.rank(siri), VoicePicker.rank(premium))
        XCTAssertGreaterThan(VoicePicker.rank(premium), VoicePicker.rank(daniel))
        XCTAssertGreaterThan(VoicePicker.rank(daniel), VoicePicker.rank(novelty))
        XCTAssertEqual(VoicePicker.label(siri), "Siri neural")
    }

    func testCloudPayloads() {
        let v = Profile.Voice()
        let el = CloudSpeechOutput(provider: .elevenlabs, voice: v).payload(for: "Good evening, Sam.")
        XCTAssertEqual(el["model_id"] as? String, "eleven_flash_v2_5")
        XCTAssertEqual(el["text"] as? String, "Good evening, Sam.")
        let oa = CloudSpeechOutput(provider: .openai, voice: v).payload(for: "Hi")
        XCTAssertEqual(oa["model"] as? String, "gpt-4o-mini-tts")
        XCTAssertEqual(oa["voice"] as? String, "fable")
        XCTAssertTrue((oa["instructions"] as? String ?? "").contains("British"))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(el) && JSONSerialization.isValidJSONObject(oa))
    }

    func testVoiceAndUIConfigDefaults() throws {
        let p = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: ConfigTests.repoConfigDir.appendingPathComponent("profile.json")))
        XCTAssertEqual(p.ui?.style, "floating")
        XCTAssertEqual(p.ui?.screen, "active")
        XCTAssertEqual(p.ui?.halo, false)
        XCTAssertEqual(p.voice?.engine, "auto")
        let empty = try JSONDecoder().decode(Profile.UI.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.position, "bottom")
    }
}

final class ScreenTests: XCTestCase {
    @MainActor
    func testActiveScreenResolves() {
        XCTAssertNotNil(ScreenResolver.target(pinned: "active"))
        XCTAssertNotNil(ScreenResolver.target(pinned: "No Such Display"), "unknown pin falls back to the active screen")
        if let s = NSScreen.screens.last {
            XCTAssertEqual(ScreenResolver.target(pinned: s.localizedName)?.localizedName, s.localizedName)
        }
    }
}
