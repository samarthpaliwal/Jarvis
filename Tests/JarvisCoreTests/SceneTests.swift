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

final class ConversationFlowTests: XCTestCase {
    func testInterruptionIgnoresEchoOfJarvis() {
        let spoken = "Good afternoon, Sam. Two things on the board today, and your midterm is in eight days."
        XCTAssertFalse(ConversationController.isGenuineInterruption(heard: "two things on the board", spoken: spoken), "echo")
        XCTAssertFalse(ConversationController.isGenuineInterruption(heard: "Sam", spoken: spoken), "single word")
        XCTAssertTrue(ConversationController.isGenuineInterruption(heard: "actually open Spotify", spoken: spoken))
        XCTAssertTrue(ConversationController.isGenuineInterruption(heard: "what about tomorrow", spoken: ""))
    }

    func testConversationEndWords() {
        XCTAssertTrue(ConversationController.isConversationEnd("Thanks."))
        XCTAssertTrue(ConversationController.isConversationEnd("that's all"))
        XCTAssertTrue(ConversationController.isConversationEnd("okay bye"))
        XCTAssertFalse(ConversationController.isConversationEnd("thanks, and also set a timer for ten minutes"))
        XCTAssertFalse(ConversationController.isConversationEnd("no, make it 3pm instead"))
    }

    func testSpeechConfigDefaultsAreLenient() throws {
        let old = #"{"locale":"en-US","silenceEndSeconds":1.3,"noSpeechTimeoutSeconds":6,"maxUtteranceSeconds":20}"#
        let s = try JSONDecoder().decode(Profile.Speech.self, from: Data(old.utf8))
        XCTAssertEqual(s.followUpSeconds, 7)
        XCTAssertTrue(s.interruptOnSpeech)
    }

    @MainActor
    func testScreenLookupByName() {
        XCTAssertNil(NotchGeometry.screen(named: nil))
        XCTAssertNil(NotchGeometry.screen(named: "No Such Monitor 9000"))
        if let first = NSScreen.screens.first {
            XCTAssertEqual(NotchGeometry.screen(named: first.localizedName)?.localizedName, first.localizedName)
        }
    }
}
