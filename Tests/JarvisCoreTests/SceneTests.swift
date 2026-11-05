import XCTest
@testable import JarvisCore

final class PhraseSpotterTests: XCTestCase {
    let phrases = [Profile.WakePhrase(phrase: "wake up daddy's home", aliases: ["daddy's home", "daddy is home"], scene: "homecoming")]

    func testMatchesVariantsAndIgnoresNoise() {
        XCTAssertEqual(PhraseSpotter.match("Wake up, Daddy's home.", phrases: phrases)?.scene, "homecoming")
        XCTAssertNotNil(PhraseSpotter.match("okay so um daddy is home now", phrases: phrases))
        XCTAssertNotNil(PhraseSpotter.match("Wake up Daddys home", phrases: phrases))
        XCTAssertNil(PhraseSpotter.match("my dad is at home today", phrases: phrases))
        XCTAssertNil(PhraseSpotter.match("", phrases: phrases))
    }

    func testOnlyTheRecentTailCounts() {
        let old = "daddy's home " + Array(repeating: "blah", count: 20).joined(separator: " ")
        XCTAssertNil(PhraseSpotter.match(old, phrases: phrases))
    }
}

final class WakeConfigTests: XCTestCase {
    func testShippedProfileHasPhraseAndPersona() throws {
        let data = try Data(contentsOf: ConfigTests.repoConfigDir.appendingPathComponent("profile.json"))
        let p = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(p.wake?.phrases.first?.scene, "homecoming")
        XCTAssertEqual(p.assistant.persona, "ironman")
        XCTAssertTrue(SystemPrompt.build(profile: p, mode: ModesConfig.fallback.modes[0]).contains("Tony Stark"))
    }

    func testOldProfileWithoutWakeStillDecodes() throws {
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: ConfigTests.repoConfigDir.appendingPathComponent("profile.json"))) as! [String: Any]
        obj["wake"] = nil; obj["hud"] = nil
        let p = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(p.wake)
    }
}
