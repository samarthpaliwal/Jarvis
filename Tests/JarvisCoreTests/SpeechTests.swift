import XCTest
@testable import JarvisCore

final class EndpointerTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testNoSpeechTimesOut() {
        let e = Endpointer(now: t0)
        XCTAssertNil(e.shouldEnd(at: t0.addingTimeInterval(5.9)))
        XCTAssertEqual(e.shouldEnd(at: t0.addingTimeInterval(6.0)), .noSpeech)
    }

    func testSilenceAfterSpeechEnds() {
        var e = Endpointer(now: t0)
        e.update(TranscriptUpdate(text: "what's", isFinal: false), at: t0.addingTimeInterval(0.5))
        e.update(TranscriptUpdate(text: "what's left today", isFinal: false), at: t0.addingTimeInterval(1.2))
        XCTAssertNil(e.shouldEnd(at: t0.addingTimeInterval(2.4)))
        XCTAssertEqual(e.shouldEnd(at: t0.addingTimeInterval(2.55)), .silenceAfterSpeech)
        XCTAssertEqual(e.transcript, "what's left today")
    }

    func testUnchangedTextDoesNotResetTimer() {
        var e = Endpointer(now: t0)
        e.update(TranscriptUpdate(text: "hello", isFinal: false), at: t0.addingTimeInterval(1))
        XCTAssertFalse(e.update(TranscriptUpdate(text: " hello ", isFinal: false), at: t0.addingTimeInterval(2)))
        XCTAssertEqual(e.shouldEnd(at: t0.addingTimeInterval(2.35)), .silenceAfterSpeech)
    }

    func testFinalResultEndsImmediately() {
        var e = Endpointer(now: t0)
        e.update(TranscriptUpdate(text: "set a timer", isFinal: true), at: t0.addingTimeInterval(1))
        XCTAssertEqual(e.shouldEnd(at: t0.addingTimeInterval(1)), .finalResult)
    }

    func testMaxDurationCaps() {
        var e = Endpointer(now: t0)
        for i in 0..<30 {
            e.update(TranscriptUpdate(text: String(repeating: "word ", count: i + 1), isFinal: false), at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(e.shouldEnd(at: t0.addingTimeInterval(20)), .maxDuration)
    }
}

final class VoicePickerTests: XCTestCase {
    func testCandidatesAreEnglishAndQualitySorted() {
        let c = VoicePicker.candidates()
        XCTAssertFalse(c.isEmpty)
        XCTAssertTrue(c.allSatisfy { $0.language.hasPrefix("en") })
        for (a, b) in zip(c, c.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.quality.rawValue, b.quality.rawValue)
        }
    }

    func testDefaultChoiceIsNotANoveltyVoice() throws {
        let best = try XCTUnwrap(VoicePicker.best(preferred: nil))
        XCTAssertFalse(best.identifier.hasPrefix("com.apple.speech.synthesis.voice."), "picked \(best.name)")
    }

    func testBestVoiceAlwaysResolves() {
        XCTAssertNotNil(VoicePicker.best(preferred: "com.apple.voice.does-not-exist"))
        XCTAssertNotNil(VoicePicker.best(preferred: nil))
    }
}

final class SpeechOutputTests: XCTestCase {
    /// Speaks at volume 0 so the test is silent, and checks the completion fires.
    @MainActor
    func testSilentUtteranceCompletes() async {
        let out = AppleSpeechOutput(preferredVoice: nil)
        XCTAssertNotNil(out.voice)
        let done = expectation(description: "finished")
        var completed: Bool?
        out.speak("Testing one two.", volume: 0, rate: 0.6) { completed = $0; done.fulfill() }
        await fulfillment(of: [done], timeout: 15)
        XCTAssertEqual(completed, true)
        XCTAssertFalse(out.isSpeaking)
    }

    @MainActor
    func testStopCancels() async {
        let out = AppleSpeechOutput(preferredVoice: nil)
        let done = expectation(description: "cancelled")
        var completed: Bool?
        out.speak("This is a much longer sentence that should be interrupted before it finishes speaking.", volume: 0, rate: 0.4) { completed = $0; done.fulfill() }
        try? await Task.sleep(for: .milliseconds(400))
        out.stop()
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(completed, false)
    }
}
