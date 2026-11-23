import XCTest
@testable import JarvisCore

final class VoiceCaptureTests: XCTestCase {
    func testPreRollIsKeptForAWakeButNotForAFollowUp() {
        let r = UtteranceRecorder(preRollSeconds: 1, maxSeconds: 5)
        r.feed([Float](repeating: 0.1, count: 32_000))            // 2 s before the wake word fires
        r.begin(includePreRoll: true)
        r.feed([Float](repeating: 0.2, count: 16_000))
        let wake = r.end()
        XCTAssertEqual(wake.count, 32_000, "1 s of pre-roll (\"Hey Jarvis\") plus 1 s of the request")
        XCTAssertEqual(wake.first, 0.1)

        r.feed([Float](repeating: 0.9, count: 16_000))            // Jarvis's own voice, just before a follow-up
        r.begin(includePreRoll: false)
        r.feed([Float](repeating: 0.2, count: 8_000))
        let followUp = r.end()
        XCTAssertEqual(followUp.count, 8_000)
        XCTAssertFalse(followUp.contains(0.9), "Jarvis's voice must not end up in the sample that is checked")
    }

    func testCaptureIsBoundedAndNothingIsKeptAfterwards() {
        let r = UtteranceRecorder(preRollSeconds: 1, maxSeconds: 2)
        r.begin(includePreRoll: false)
        for _ in 0..<100 { r.feed([Float](repeating: 0.1, count: 1_280)) }
        XCTAssertLessThanOrEqual(r.end().count, 2 * 16_000 + 1_280)
        XCTAssertTrue(r.end().isEmpty, "handed over once, then gone")
        r.begin(includePreRoll: false); r.feed([0.1]); r.discard()
        XCTAssertTrue(r.end().isEmpty)
    }
}

final class VoiceGateRuleTests: XCTestCase {
    func check(_ o: VoiceCheck.Outcome, _ score: Double? = nil) -> VoiceCheck { VoiceCheck(outcome: o, score: score, seconds: 3) }

    func testRules() {
        // Voice ID off: nothing changes.
        XCTAssertEqual(VoiceGate.decide(check: check(.mismatch, 0.1), enrolled: false, policy: "button"), .voiceOrButton)
        XCTAssertEqual(VoiceGate.decide(check: nil, enrolled: false, policy: "never"), .voiceOrButton)
        // The owner's voice: a spoken yes counts.
        XCTAssertEqual(VoiceGate.decide(check: check(.verified, 0.8), enrolled: true, policy: "button"), .voiceOrButton)
        XCTAssertTrue(VoiceGate.decide(check: check(.verified, 0.8), enrolled: true, policy: "never").acceptsSpokenYes)
        // Someone else, or not enough speech: the button only, or nothing at all.
        for outcome in [VoiceCheck.Outcome.mismatch, .tooShort, .unavailable] {
            let button = VoiceGate.decide(check: check(outcome, 0.2), enrolled: true, policy: "button")
            XCTAssertFalse(button.acceptsSpokenYes, "\(outcome)")
            if case .buttonOnly(let why) = button { XCTAssertTrue(why.hasSuffix("approve it on screen")) } else { XCTFail("\(outcome)") }
            if case .refuse(let why) = VoiceGate.decide(check: check(outcome, 0.2), enrolled: true, policy: "never") { XCTAssertTrue(why.hasSuffix("so I won't do that.")) } else { XCTFail("\(outcome)") }
        }
        // Typed: there is no voice, so a voice in the room cannot approve it.
        XCTAssertFalse(VoiceGate.decide(check: nil, enrolled: true, policy: "button").acceptsSpokenYes)
    }
}

final class SentenceRecorderTests: XCTestCase {
    func feed(_ r: inout SentenceRecorder, _ audio: [Float]) {
        var i = 0
        while i < audio.count { r.feed(Array(audio[i..<min(i + 1_280, audio.count)])); i += 1_280 }
    }

    func testCutsOneSentenceOutOfTheStream() {
        var r = SentenceRecorder()
        feed(&r, FakeEmbedder.silence(0.6))
        XCTAssertEqual(r.status, .waiting)
        feed(&r, FakeEmbedder.audio(voice: 2, seconds: 2.5))
        XCTAssertEqual(r.status, .recording)
        feed(&r, FakeEmbedder.silence(1.2))
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(r.spoken, 2.5, accuracy: 0.2)
        XCTAssertGreaterThan(r.samples.count, Int(2.5 * 16_000))
        XCTAssertLessThan(r.samples.count, Int(4.2 * 16_000), "the long silence before speaking is not part of the sample")
    }

    func testAShortNoiseIsNotASentenceAndSilenceTimesOut() {
        var r = SentenceRecorder()
        feed(&r, FakeEmbedder.audio(voice: 2, seconds: 0.4))      // a cough
        feed(&r, FakeEmbedder.silence(2))
        XCTAssertEqual(r.status, .recording, "still waiting for a real sentence")
        var quiet = SentenceRecorder()
        feed(&quiet, FakeEmbedder.silence(13))
        XCTAssertEqual(quiet.status, .timedOut)
    }

    func testRealSpeechFixtureIsCapturedWhole() throws {
        let clip = try ECAPAModelTests().wav("bm_george_0")
        var r = SentenceRecorder()
        feed(&r, FakeEmbedder.silence(0.5) + clip + FakeEmbedder.silence(1.2))
        XCTAssertEqual(r.status, .done)
        XCTAssertGreaterThan(Double(r.samples.count) / 16_000, Double(clip.count) / 16_000 * 0.85, "natural pauses inside a sentence must not end it early")
    }
}

@MainActor
final class FakeEnrollmentHost: EnrollmentHost {
    var said: [String] = []
    var shown: [String] = []
    var begun = 0, ended = 0
    var busy = false
    /// What the "user" says at each tone: a voice number, or nil for silence.
    var script: [Int?] = []
    private var feeder: Task<Void, Never>?

    func beginEnrollment() -> Bool { if busy { return false }; begun += 1; return true }
    func endEnrollment() { ended += 1 }
    func say(_ text: String) async { said.append(text) }
    func show(title: String, text: String) { shown.append("\(title): \(text)") }
    func tone() async {}
    func listen(_ onChunk: @escaping @Sendable ([Float]) -> Void) -> () -> Void {
        let next = script.isEmpty ? nil : script.removeFirst()
        let audio = next.map { FakeEmbedder.audio(voice: $0, seconds: 2.4) + FakeEmbedder.silence(1.2) } ?? FakeEmbedder.silence(13)
        feeder = Task.detached {
            var i = 0
            while i < audio.count, !Task.isCancelled { onChunk(Array(audio[i..<min(i + 12_800, audio.count)])); i += 12_800 }
        }
        return { [weak self] in self?.feeder?.cancel() }
    }
}

@MainActor
final class VoiceEnrollmentTests: XCTestCase {
    var url: URL!
    override func setUp() { url = FileManager.default.temporaryDirectory.appendingPathComponent("voiceprint-\(UUID().uuidString)/voiceprint.json") }
    override func tearDown() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    func enrollment(_ host: FakeEnrollmentHost) -> (VoiceEnrollment, SpeakerVerifier) {
        let v = SpeakerVerifier(embedder: FakeEmbedder(), store: VoiceprintStore(url: url))
        let e = VoiceEnrollment(verifier: v, host: host)
        e.pollMilliseconds = 2
        return (e, v)
    }

    func testFiveSentencesThenAVoiceprint() async {
        let host = FakeEnrollmentHost()
        host.script = [4, 4, 4, 4, 4]
        let (e, v) = enrollment(host)
        let outcome = await e.run()
        XCTAssertEqual(outcome, .enrolled(samples: 5, consistency: 1))
        XCTAssertTrue(v.isEnrolled)
        XCTAssertEqual(v.verify(FakeEmbedder.audio(voice: 4)).outcome, .verified)
        XCTAssertEqual(v.verify(FakeEmbedder.audio(voice: 1)).outcome, .mismatch)
        XCTAssertEqual(host.shown.filter { $0.hasPrefix("Voice ID ") && $0.contains(" of 5") }.count, 5, "each sentence is shown")
        XCTAssertTrue(host.said.first!.contains("After each tone"))
        XCTAssertTrue(host.said.last!.contains("Voice ID is set up"))
        XCTAssertEqual(host.begun, 1); XCTAssertEqual(host.ended, 1, "the microphone is handed back")
    }

    func testAMissedSentenceIsAskedAgain() async {
        let host = FakeEnrollmentHost()
        host.script = [4, nil, 4, 4, 4, 4]                     // said nothing the second time
        let (e, v) = enrollment(host)
        e.sentences = Array(VoiceEnrollment.sentences.prefix(5))
        var recorder = SentenceRecorder(); recorder.maxSeconds = 12
        let outcome = await e.run()
        XCTAssertEqual(outcome, .enrolled(samples: 5, consistency: 1))
        XCTAssertTrue(host.said.contains("I didn't catch that. Once more after the tone."))
        XCTAssertTrue(v.isEnrolled)
    }

    func testGivingUpSavesNothing() async {
        let host = FakeEnrollmentHost()
        host.script = [4, nil, nil, nil]
        let (e, v) = enrollment(host)
        let outcome = await e.run()
        if case .failed = outcome {} else { XCTFail("\(outcome)") }
        XCTAssertFalse(v.isEnrolled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(host.said.last!.contains("Nothing was saved"))
        XCTAssertEqual(host.ended, 1)
    }

    func testTwoPeopleTakingTurnsDoNotMakeAVoiceprint() async {
        let host = FakeEnrollmentHost()
        host.script = [1, 3, 5, 7, 2]
        let (e, v) = enrollment(host)
        let outcome = await e.run()
        if case .failed = outcome {} else { XCTFail("\(outcome)") }
        XCTAssertFalse(v.isEnrolled)
    }

    func testBusyJarvisDoesNotStart() async {
        let host = FakeEnrollmentHost(); host.busy = true
        let (e, _) = enrollment(host)
        let outcome = await e.run()
        XCTAssertEqual(outcome, .busy)
        XCTAssertTrue(host.said.isEmpty)
    }
}

/// Item 15: a spoken request is checked, and approvals are gated on the result.
@MainActor
final class VoiceGatedApprovalTests: XCTestCase {
    let rig = PipelineStagesTests()
    var url: URL!
    override func setUp() async throws { url = FileManager.default.temporaryDirectory.appendingPathComponent("voiceprint-\(UUID().uuidString)/voiceprint.json") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    struct Setup { let c: ConversationController; let wake: FakeWake; let stt: FakeTranscriber; let intent: FakeIntent; let speech: FakeSpeech; let notch: NotchViewModel; let request: ApprovalRequest }

    func make(enrolledVoice: Int? = 3, env: [String: String] = [:]) throws -> (Setup, () -> Bool?) {
        let wake = FakeWake(), stt = FakeTranscriber(), intent = FakeIntent(), speech = FakeSpeech(), notch = NotchViewModel()
        var e = env; e["JARVIS_FOLLOW_UP_GUARD_MILLISECONDS"] = "10"; e["JARVIS_APPROVAL_TIMEOUT_SECONDS"] = "3"
        let c = rig.makeController(wake, stt, intent, speech, env: e, notch: notch)
        let v = SpeakerVerifier(embedder: FakeEmbedder(), store: VoiceprintStore(url: url))
        if let enrolledVoice { try v.enroll((0..<3).map { _ in FakeEmbedder.audio(voice: enrolledVoice) }) }
        c.voiceID = v
        let request = ApprovalRequest(toolName: "email_send", preview: "Send the email to maya@example.com")
        var decision: Bool?
        intent.duringReply = { decision = await c.requestApproval(request) }
        return (Setup(c: c, wake: wake, stt: stt, intent: intent, speech: speech, notch: notch, request: request), { decision })
    }

    func speak(_ s: Setup, voice: Int, text: String) {
        s.wake.fire()
        let audio = FakeEmbedder.audio(voice: voice, seconds: 2.5)
        var i = 0
        while i < audio.count { s.wake.audioTap?(Array(audio[i..<min(i + 1_280, audio.count)])); i += 1_280 }
        s.stt.say(text)
    }

    func testTheOwnersVoiceCanApproveBySayingYes() async throws {
        let (s, decision) = try make()
        speak(s, voice: 3, text: "send it")
        await rig.wait("the approval prompt") { s.speech.spoken.contains("Approve: Send the email to maya@example.com? Say yes or no.") }
        XCTAssertEqual(s.c.lastVoiceCheck?.outcome, .verified)
        s.speech.finishSpeaking()
        await rig.wait("listening for the answer") { s.stt.starts >= 2 }
        s.stt.say("yes")
        await rig.wait("a decision") { decision() != nil }
        XCTAssertEqual(decision(), true)
    }

    func testAnotherVoiceCannotApproveBySayingYesButTheButtonStillWorks() async throws {
        let (s, decision) = try make()
        speak(s, voice: 6, text: "send it")                      // not the enrolled voice
        await rig.wait("the prompt") { s.speech.spoken.contains { $0.hasPrefix("I couldn't verify your voice, so approve it on screen: Send the email") } }
        XCTAssertEqual(s.c.lastVoiceCheck?.outcome, .mismatch)
        s.speech.finishSpeaking()
        await rig.wait("listening") { s.stt.starts >= 2 }
        s.stt.say("yes")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(decision(), "a spoken yes from an unverified voice changes nothing")
        XCTAssertEqual(s.c.state, .awaitingApproval)
        s.notch.onApprovalDecision?(s.request.id, true)          // someone at the Mac clicks Approve
        await rig.wait("a decision") { decision() != nil }
        XCTAssertEqual(decision(), true)
    }

    func testAnUnverifiedVoiceCanStillSayNo() async throws {
        let (s, decision) = try make()
        speak(s, voice: 6, text: "send it")
        await rig.wait("the prompt") { s.speech.isWaitingToFinish }
        s.speech.finishSpeaking()
        await rig.wait("listening") { s.stt.starts >= 2 }
        s.stt.say("no")
        await rig.wait("a decision") { decision() != nil }
        XCTAssertEqual(decision(), false, "refusing is always allowed")
    }

    func testStrictPolicyRefusesOutrightAndSaysWhy() async throws {
        let (s, decision) = try make(env: ["JARVIS_UNVERIFIED_VOICE_APPROVAL": "never"])
        speak(s, voice: 6, text: "send it")
        await rig.wait("a decision") { decision() != nil }
        XCTAssertEqual(decision(), false)
        XCTAssertTrue(s.speech.spoken.contains("I couldn't verify your voice, so I won't do that."), "\(s.speech.spoken)")
        XCTAssertNotEqual(s.c.state, .awaitingApproval, "no approval card is even shown")
    }

    func testATypedRequestNeedsTheButton() async throws {
        let (s, decision) = try make()
        s.c.ask("send it")
        await rig.wait("the prompt") { s.speech.spoken.contains { $0.hasPrefix("That was typed, so approve it on screen: Send the email") } }
        s.speech.finishSpeaking()
        await rig.wait("listening") { s.stt.starts >= 1 }
        s.stt.say("yes")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(decision(), "nobody's voice was checked, so a voice in the room cannot approve")
        s.notch.onApprovalDecision?(s.request.id, true)
        await rig.wait("a decision") { decision() != nil }
        XCTAssertEqual(decision(), true)
    }

    func testWithoutEnrollmentNothingChanges() async throws {
        let (s, decision) = try make(enrolledVoice: nil)
        speak(s, voice: 6, text: "send it")
        await rig.wait("the prompt") { s.speech.spoken.contains("Approve: Send the email to maya@example.com? Say yes or no.") }
        s.speech.finishSpeaking()
        await rig.wait("listening") { s.stt.starts >= 2 }
        s.stt.say("yes")
        await rig.wait("a decision") { decision() != nil }
        XCTAssertEqual(decision(), true)
    }

    func testTheScoreIsTracedButNeverTheVoiceprint() async throws {
        let (s, decision) = try make()
        speak(s, voice: 3, text: "send it")
        await rig.wait("the prompt") { s.speech.isWaitingToFinish }
        let trace = s.c.trace
        s.notch.onApprovalDecision?(s.request.id, false)
        await rig.wait("a decision") { decision() != nil }
        let summary = trace!.finish(outcome: "x")
        let speaker = summary["speaker"] as? [String: Any]
        XCTAssertEqual(speaker?["outcome"] as? String, "verified")
        XCTAssertEqual(speaker?["score"] as? Double, 1)
        XCTAssertNil(speaker?["embedding"])
        XCTAssertFalse(String(describing: summary).contains("0.0, 0.0, 0.0"), "no vector in the trace")
    }
}
