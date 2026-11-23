import XCTest
@testable import JarvisCore

/// A stand-in embedder: the "voice" is encoded in how loud the audio is, so it survives trimming, padding,
/// and being cut into chunks. Lets enrollment and gating be tested without the model file.
final class FakeEmbedder: SpeakerEmbedding, @unchecked Sendable {
    let modelName = "fake"
    static func voice(_ id: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        v[((id % 8) + 8) % 8] = 1
        return v
    }
    /// A steady alternating signal whose amplitude names the voice: 0.10 + 0.05 × id.
    static func audio(voice: Int, seconds: Double = 3) -> [Float] {
        let amp = 0.10 + 0.05 * Float(voice)
        return (0..<Int(seconds * 16_000)).map { $0 % 2 == 0 ? amp : -amp }
    }
    static func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }
    func embed(_ samples: [Float]) throws -> [Float] {
        guard Double(samples.count) / 16_000 >= 0.6 else { throw VoiceIDError.tooShort(Double(samples.count) / 16_000) }
        let peak = samples.map(abs).max() ?? 0
        return Self.voice(Int(((peak - 0.10) / 0.05).rounded()))
    }
}

final class VoiceMathTests: XCTestCase {
    func testCosineAndCentroid() {
        XCTAssertEqual(VoiceMath.cosine([1, 0], [1, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(VoiceMath.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(VoiceMath.cosine([1, 0], [-1, 0]), -1, accuracy: 1e-6)
        XCTAssertEqual(VoiceMath.cosine([], []), 0)
        let c = VoiceMath.centroid([[1, 0], [0, 1]])
        XCTAssertEqual(c[0], c[1], accuracy: 1e-6)
        XCTAssertEqual(VoiceMath.cosine(c, c), 1, accuracy: 1e-6)
    }

    func testSilenceIsTrimmedFromBothEnds() {
        let quiet = [Float](repeating: 0.0005, count: 16_000)
        let speech = (0..<32_000).map { Float(sin(Double($0) * 0.2)) * 0.3 }
        let trimmed = VoiceMath.trimSilence(quiet + speech + quiet)
        XCTAssertLessThan(trimmed.count, 32_000 + 2 * 3_200 + 400)
        XCTAssertGreaterThanOrEqual(trimmed.count, 32_000 - 400)
        XCTAssertTrue(VoiceMath.trimSilence(quiet).isEmpty, "silence only: nothing to verify")
    }

    func testFilterbankShape() {
        XCTAssertEqual(Fbank.frameCount(16_000), 98)
        XCTAssertEqual(Fbank.frameCount(399), 0)
        let tone = (0..<16_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) * 0.5 }
        let (frames, f) = Fbank.compute(tone)
        XCTAssertEqual(frames, 98)
        XCTAssertEqual(f.count, 98 * 80)
        XCTAssertTrue(f.allSatisfy { $0.isFinite })
        // Mean-normalized: every bin averages to zero over time.
        for b in [0, 20, 79] {
            let mean = (0..<frames).map { f[$0 * 80 + b] }.reduce(0, +) / Float(frames)
            XCTAssertEqual(mean, 0, accuracy: 1e-3)
        }
        XCTAssertEqual(Fbank.filters.count, 80 * 256)
        XCTAssertTrue(Fbank.filters.allSatisfy { $0 >= 0 && $0 <= 1 })
    }
}

/// Enrollment and verification logic, on the fake embedder.
final class SpeakerVerifierTests: XCTestCase {
    var url: URL!
    override func setUp() { url = FileManager.default.temporaryDirectory.appendingPathComponent("voiceprint-\(UUID().uuidString)/voiceprint.json") }
    override func tearDown() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    func verifier() -> SpeakerVerifier { SpeakerVerifier(embedder: FakeEmbedder(), store: VoiceprintStore(url: url), threshold: 0.5) }

    func testEnrollThenRecognizeTheOwnerAndRejectAnotherVoice() throws {
        let v = verifier()
        XCTAssertEqual(v.verify(FakeEmbedder.audio(voice: 3)).outcome, .notEnrolled)
        let print = try v.enroll((0..<5).map { _ in FakeEmbedder.audio(voice: 3) })
        XCTAssertEqual(print.samples, 5)
        XCTAssertTrue(v.isEnrolled)
        let me = v.verify(FakeEmbedder.audio(voice: 3))
        XCTAssertEqual(me.outcome, .verified)
        XCTAssertEqual(me.score ?? 0, 1, accuracy: 1e-4)
        let other = v.verify(FakeEmbedder.audio(voice: 5))
        XCTAssertEqual(other.outcome, .mismatch)
        XCTAssertFalse(other.isVerified)
        XCTAssertTrue(other.isEnforced)
    }

    func testTooLittleSpeechIsNotAVerdict() throws {
        let v = verifier()
        try v.enroll((0..<3).map { _ in FakeEmbedder.audio(voice: 3) })
        XCTAssertEqual(v.verify(FakeEmbedder.audio(voice: 3, seconds: 0.3)).outcome, .tooShort)
        XCTAssertEqual(v.verify([Float](repeating: 0, count: 32_000)).outcome, .tooShort, "silence is not a voice")
    }

    func testEnrollmentNeedsThreeGoodRecordingsOfOneVoice() {
        let v = verifier()
        XCTAssertThrowsError(try v.enroll([FakeEmbedder.audio(voice: 3), FakeEmbedder.audio(voice: 3)])) { XCTAssertEqual($0 as? VoiceIDError, .notEnoughSamples(2)) }
        XCTAssertThrowsError(try v.enroll((0..<5).map { _ in FakeEmbedder.audio(voice: 3, seconds: 0.8) }), "recordings that are too short are not used")
        // Three different people: no voiceprint.
        XCTAssertThrowsError(try v.enroll([1, 3, 5].map { FakeEmbedder.audio(voice: $0) })) { error in
            if case .inconsistent = error as? VoiceIDError {} else { XCTFail("\(error)") }
        }
        XCTAssertFalse(v.isEnrolled)
    }

    func testOneBadRecordingIsDroppedNotFatal() throws {
        let v = verifier()
        let print = try v.enroll([3, 3, 3, 3, 6].map { FakeEmbedder.audio(voice: $0) })
        XCTAssertEqual(print.samples, 4, "the cough is left out")
        XCTAssertEqual(v.verify(FakeEmbedder.audio(voice: 3)).outcome, .verified)
        XCTAssertEqual(v.verify(FakeEmbedder.audio(voice: 6)).outcome, .mismatch)
    }

    func testVoiceprintSurvivesARestartAndCanBeForgotten() throws {
        try verifier().enroll((0..<3).map { _ in FakeEmbedder.audio(voice: 2) })
        let again = verifier()                         // a new process
        XCTAssertTrue(again.isEnrolled)
        XCTAssertEqual(again.verify(FakeEmbedder.audio(voice: 2)).outcome, .verified)
        again.forget()
        XCTAssertFalse(again.isEnrolled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(verifier().verify(FakeEmbedder.audio(voice: 2)).outcome, .notEnrolled)
    }

    // Item 16: local only.
    func testVoiceprintFileIsPrivateAndHoldsNoAudio() throws {
        try verifier().enroll((0..<3).map { _ in FakeEmbedder.audio(voice: 2) })
        let fm = FileManager.default
        XCTAssertEqual((try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600, "only this user can read the file")
        XCTAssertEqual((try fm.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThan(size, 8_000, "an embedding, not a recording")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["voiceprint.json"], "no audio files are kept")
    }

    func testAVoiceprintFromAnotherModelIsIgnored() throws {
        try VoiceprintStore(url: url).save(Voiceprint(model: "some-other-model", embedding: [1, 0], samples: 5, createdAt: Date(), selfScoreMin: 1, selfScoreMean: 1))
        XCTAssertFalse(verifier().isEnrolled, "embeddings from different models are not comparable")
    }

    @MainActor func testVoiceprintFolderIsOffLimitsToTools() {
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        let guardian = DenylistGuard(denylist: config.denylist, allowedFolders: config.allowedFolders)
        XCTAssertThrowsError(try guardian.check(ToolTargets(paths: ["~/Library/Application Support/Jarvis/voiceprint/voiceprint.json"])))
        XCTAssertTrue(Denylist.fallback.paths.contains("~/Library/Application Support/Jarvis/voiceprint"), "part of the hard-coded floor, not just the editable file")
    }
}

/// The real model on real audio files. Skipped when the model is not installed (scripts/setup-voiceid.sh).
final class ECAPAModelTests: XCTestCase {
    static let fixtures = ConfigTests.repoConfigDir.deletingLastPathComponent().appendingPathComponent("Tests/JarvisCoreTests/Fixtures/voices")

    func wav(_ name: String) throws -> [Float] {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name + ".wav"))
        let pcm = data.dropFirst(44)                    // canonical 44-byte header, 16-bit mono
        return pcm.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 } }
    }

    func embedder() throws -> ECAPAEmbedder {
        guard FileManager.default.fileExists(atPath: ECAPAEmbedder.defaultURL.path) else { throw XCTSkip("voice model not installed; run scripts/setup-voiceid.sh") }
        return try ECAPAEmbedder()
    }

    func testSwiftPipelineMatchesThePythonReference() throws {
        let model = try embedder()
        let reference = try JSONDecoder().decode([String: [Float]].self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("reference-embeddings.json")))
        XCTAssertEqual(reference.count, 6)
        for (name, expected) in reference {
            let got = try model.embed(try wav(name))
            XCTAssertEqual(got.count, 192)
            XCTAssertGreaterThan(VoiceMath.cosine(got, expected), 0.999, "\(name): the Swift features or model call differ from the reference")
        }
    }

    func testSameVoiceScoresHighAndDifferentVoicesScoreLow() throws {
        let model = try embedder()
        let george = try (0..<3).map { try model.embed(try wav("bm_george_\($0)")) }
        let michael = try (0..<3).map { try model.embed(try wav("am_michael_\($0)")) }
        for i in 0..<3 { for j in (i + 1)..<3 {
            XCTAssertGreaterThan(VoiceMath.cosine(george[i], george[j]), 0.6)
            XCTAssertGreaterThan(VoiceMath.cosine(michael[i], michael[j]), 0.6)
        } }
        for g in george { for m in michael { XCTAssertLessThan(VoiceMath.cosine(g, m), 0.4) } }
    }

    func testEnrollOnTwoClipsWorthOfAVoiceThenVerifyAHeldOutClip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voiceprint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = SpeakerVerifier(embedder: try embedder(), store: VoiceprintStore(url: dir.appendingPathComponent("voiceprint.json")), threshold: 0.5)
        let clips = try (0..<3).map { try wav("bm_george_\($0)") }
        // Three recordings from two clips cut differently, and the third clip held out for the test.
        let half = clips[0].count / 2
        try v.enroll([clips[0], clips[1], Array(clips[0][..<half]) + Array(clips[1][half...])])
        let own = v.verify(clips[2])
        XCTAssertEqual(own.outcome, .verified, "score \(own.score ?? -1)")
        let other = v.verify(try wav("am_michael_2"))
        XCTAssertEqual(other.outcome, .mismatch, "score \(other.score ?? -1)")
        XCTAssertGreaterThan((own.score ?? 0) - (other.score ?? 1), 0.3, "a clear margin between the owner and someone else")
    }

    func testEmbeddingIsFast() throws {
        let model = try embedder()
        let clip = try wav("bm_george_0")
        _ = try model.embed(clip)                       // warm up
        let started = Date()
        for _ in 0..<5 { _ = try model.embed(clip) }
        let ms = Date().timeIntervalSince(started) / 5 * 1000
        print("VOICEID embed \(String(format: "%.1f", Double(clip.count) / 16_000)) s of audio in \(Int(ms)) ms")
        XCTAssertLessThan(ms, 500)
    }
}
