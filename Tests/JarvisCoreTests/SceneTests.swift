import CoreAudio
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

final class EchoGuardTests: XCTestCase {
    // Real pairs from conversations.log on 2026-11-19 and 2026-11-20: what the mic "heard" was Jarvis.
    let realEchoes: [(heard: String, spoken: String)] = [
        ("Good morning, sir. I'm not certain what heads on was meant to say, though so can you tell you what you' like?",
         "Good morning, Sam, it's six o'clock and I'm fully online. I'm not certain what \"heads on\" was meant to say, though, so can you tell me what you'd like?"),
        ("It reads like, what did you want to know about 8 degrees and in which city or unit?",
         "That reads like my own reply echoed back, Sam, so I'm still missing the actual question. What did you want to know about 8 degrees, and in which city or unit?"),
        ("Good morning, Sam. Seven o'clock on a Friday, and all systems are standing by. Shall I run through your briefing?",
         "Good morning, Sam. Seven o'clock on a Friday, and all systems are standing by. Shall I run through your briefing?"),
        ("Close enough, so press play once. Would you like it hands free next time, open the Javavis making choose integrations",
         "Close enough, Sam. Press play once in Spotify to start the workout music. If you'd like it hands-free next time, open the Jarvis menu, choose Integrations, then Set Spotify Client."),
    ]

    func testRealEchoesAreCaughtAfterSpeaking() {
        for e in realEchoes {
            let sim = EchoGuard.similarity(heard: e.heard, spoken: e.spoken)
            XCTAssertTrue(EchoGuard.isEchoAfterSpeaking(heard: e.heard, spoken: e.spoken), "missed echo (\(sim)): \(e.heard.prefix(50))")
            XCTAssertTrue(EchoGuard.isEchoWhileSpeaking(heard: e.heard, spoken: e.spoken))
        }
    }

    func testAnsweringInJarvisOwnWordsIsNotEcho() {
        let spoken = "I did catch play workout music. Shall I start something on Spotify for your six o'clock session?"
        for answer in ["Yes, start something on Spotify", "Yes please", "No, play it at seven instead", "Start it, and turn the volume up a bit"] {
            XCTAssertFalse(EchoGuard.isEchoAfterSpeaking(heard: answer, spoken: spoken), answer)
        }
        XCTAssertFalse(EchoGuard.isEchoAfterSpeaking(heard: "What's the weather like in Singapore tomorrow morning?", spoken: spoken))
    }

    func testWhileSpeakingIsStrictButLetsRealInterruptionsThrough() {
        let spoken = "Good morning, Sam. You have two things on the board today, and the weather is clear."
        XCTAssertTrue(EchoGuard.isEchoWhileSpeaking(heard: "two things on the bored", spoken: spoken), "garbled echo")
        XCTAssertTrue(EchoGuard.isEchoWhileSpeaking(heard: "you have full", spoken: spoken))
        XCTAssertFalse(EchoGuard.isEchoWhileSpeaking(heard: "actually open Spotify", spoken: spoken))
        XCTAssertFalse(EchoGuard.isEchoWhileSpeaking(heard: "anything", spoken: ""), "nothing was said, so nothing can echo")
    }

    func testStemMatchingHandlesRecognizerGarbling() {
        XCTAssertTrue(EchoGuard.same("transcripts", "transcription"))
        XCTAssertFalse(EchoGuard.same("the", "then"))
        XCTAssertFalse(EchoGuard.same("play", "pause"))
    }

    func testHeadphoneDetection() {
        XCTAssertTrue(AudioDeviceInfo.isHeadphones(transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil))
        XCTAssertTrue(AudioDeviceInfo.isHeadphones(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: 0x6864706E), "headphone jack")
        XCTAssertFalse(AudioDeviceInfo.isHeadphones(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: 0x6973706B), "internal speakers")
        XCTAssertFalse(AudioDeviceInfo.isHeadphones(transport: kAudioDeviceTransportTypeHDMI, dataSource: nil), "monitor speakers")
        XCTAssertFalse(AudioDeviceInfo.isHeadphones(transport: kAudioDeviceTransportTypeAggregate, dataSource: nil))
    }
}
