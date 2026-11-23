import CoreGraphics
import XCTest
@testable import JarvisCore

private func face(eyeY: CGFloat = 100, left: CGFloat = 100, right: CGFloat = 180, noseX: CGFloat = 140, openness: Double = 0.3) -> FaceObservation {
    FaceObservation(box: CGRect(x: 60, y: 40, width: 160, height: 200), leftEye: CGPoint(x: left, y: eyeY), rightEye: CGPoint(x: right, y: eyeY),
                    nose: CGPoint(x: noseX, y: eyeY + 45), mouthLeft: CGPoint(x: left + 8, y: eyeY + 90), mouthRight: CGPoint(x: right - 8, y: eyeY + 90),
                    eyeOpenness: openness)
}

private func blankImage(_ w: Int = 320, _ h: Int = 240) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

/// A unit vector that is `score` alike to the "owner" direction [1, 0, 0…].
private func vector(score: Double) -> [Float] {
    var v = [Float](repeating: 0, count: 8)
    v[0] = Float(score); v[1] = Float((1 - score * score).squareRoot())
    return v
}
private let ownerTemplate = try! FaceTemplate.build((0..<20).map { _ in vector(score: 1) }, model: "fake", now: Date(timeIntervalSince1970: 1_700_000_000))

final class FaceMathTests: XCTestCase {
    func testSimilarityCarriesPointsOntoTheTemplate() throws {
        // The template, turned 20 degrees, doubled in size and moved: the transform must undo all three.
        let turn = CGAffineTransform(rotationAngle: 0.35).scaledBy(x: 2, y: 2).concatenating(CGAffineTransform(translationX: 300, y: 120))
        let moved = FaceAlign.template.map { $0.applying(turn) }
        let t = try XCTUnwrap(FaceAlign.similarity(from: moved, to: FaceAlign.template))
        for (p, want) in zip(moved, FaceAlign.template) {
            let got = p.applying(t)
            XCTAssertEqual(got.x, want.x, accuracy: 0.01); XCTAssertEqual(got.y, want.y, accuracy: 0.01)
        }
        XCTAssertNil(FaceAlign.similarity(from: [CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 1)], to: [.zero, CGPoint(x: 1, y: 0)]))
    }

    func testTinyFacesAreNotMeasured() {
        XCTAssertNil(FaceAlign.transform(for: face(left: 100, right: 110)))
        XCTAssertNotNil(FaceAlign.transform(for: face()))
    }

    func testNoseOffsetIgnoresSizeAndTilt() {
        XCTAssertEqual(face().noseOffset, 0, accuracy: 0.001)
        XCTAssertEqual(face(noseX: 148).noseOffset, 0.1, accuracy: 0.001)
        // Twice as big: same offset.
        var big = face(left: 200, right: 360, noseX: 296)
        XCTAssertEqual(big.noseOffset, 0.1, accuracy: 0.001)
        big.rightEye.y += 30      // head tilted: still measured along the eye line
        XCTAssertEqual(big.noseOffset, 0.1, accuracy: 0.06)
    }

    func testEyeOpennessIsHeightOverWidth() {
        let open = [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: -3), CGPoint(x: 10, y: -3), CGPoint(x: 15, y: 0), CGPoint(x: 10, y: 3), CGPoint(x: 5, y: 3)]
        let shut = open.map { CGPoint(x: $0.x, y: $0.y / 6) }
        XCTAssertEqual(VisionFaceDetector.openness(open), 0.4, accuracy: 0.01)
        XCTAssertLessThan(VisionFaceDetector.openness(shut), 0.1)
        let tilted = open.map { $0.applying(CGAffineTransform(rotationAngle: 0.5)) }
        XCTAssertEqual(VisionFaceDetector.openness(tilted), 0.4, accuracy: 0.01)
    }

    func testCropPutsTheEyesWhereTheModelExpectsThem() throws {
        // A picture with a red dot on the left eye and a green dot on the right eye (top-left coordinates).
        let w = 320, h = 240, f = face()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        func dot(_ p: CGPoint, _ c: CGColor) { ctx.setFillColor(c); ctx.fillEllipse(in: CGRect(x: p.x - 8, y: CGFloat(h) - p.y - 8, width: 16, height: 16)) }
        dot(f.leftEye, CGColor(red: 1, green: 0, blue: 0, alpha: 1)); dot(f.rightEye, CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        let crop = try XCTUnwrap(SFaceEmbedder.crop(ctx.makeImage()!, face: f))
        XCTAssertEqual(crop.count, 3 * 112 * 112)
        let plane = 112 * 112
        func rgb(_ x: Int, _ y: Int) -> (Float, Float, Float) { (crop[y * 112 + x], crop[plane + y * 112 + x], crop[2 * plane + y * 112 + x]) }
        let left = rgb(38, 52), right = rgb(74, 52), cheek = rgb(56, 80)
        XCTAssertGreaterThan(left.0, 200); XCTAssertLessThan(left.1, 60)        // red, in the red plane, at the left-eye spot
        XCTAssertGreaterThan(right.1, 200); XCTAssertLessThan(right.0, 60)      // green at the right-eye spot
        XCTAssertGreaterThan(cheek.2, 200)                                      // the blue background elsewhere, 0 to 255
    }
}

final class LivenessTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func feed(_ tracker: inout LivenessTracker, _ samples: [(Double, Double)], step: TimeInterval = 0.15, from: TimeInterval = 0) {
        for (i, s) in samples.enumerated() { tracker.add(openness: s.0, noseOffset: s.1, at: t0.addingTimeInterval(from + Double(i) * step)) }
    }

    func testAStillFaceIsNotLive() {
        var t = LivenessTracker()
        feed(&t, (0..<40).map { i in (0.30 + (i % 2 == 0 ? 0.01 : -0.01), 0.02 + (i % 3 == 0 ? 0.01 : 0)) })
        XCTAssertFalse(t.isLive, "a photo: steady eyes, steady nose, a little camera noise")
    }

    func testABlinkIsLive() {
        var t = LivenessTracker()
        feed(&t, [(0.30, 0), (0.31, 0), (0.30, 0), (0.29, 0), (0.30, 0), (0.12, 0), (0.10, 0), (0.29, 0), (0.30, 0)])
        XCTAssertTrue(t.isLive); XCTAssertEqual(t.reason, "blink")
    }

    func testEyesThatStayShutAreNotABlink() {
        var t = LivenessTracker()
        feed(&t, [(0.30, 0), (0.31, 0), (0.30, 0), (0.29, 0), (0.30, 0)] + Array(repeating: (0.10, 0.0), count: 12) + [(0.30, 0)])
        XCTAssertFalse(t.isLive, "closed for well over a second, then open: not a natural blink")
    }

    func testAHeadTurnIsLive() {
        var t = LivenessTracker()
        feed(&t, (0..<14).map { i in (0.30, Double(i) * 0.012) })
        XCTAssertTrue(t.isLive); XCTAssertEqual(t.reason, "head turn")
    }

    func testOneJitteryFrameIsNotAHeadTurn() {
        var t = LivenessTracker()
        var s = Array(repeating: (0.30, 0.0), count: 14); s[7] = (0.30, 0.2)
        feed(&t, s)
        XCTAssertFalse(t.isLive)
    }

    func testAGapStartsAgain() {
        var t = LivenessTracker()
        feed(&t, (0..<14).map { i in (0.30, Double(i) * 0.012) })
        XCTAssertTrue(t.isLive)
        t.add(openness: 0.3, noseOffset: 0, at: t0.addingTimeInterval(60))
        XCTAssertFalse(t.isLive, "after a gap it may be someone else: prove it again")
    }
}

final class OwnerPresenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 5_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private let me = FaceFrame.faces([.init(score: 0.7, live: true)])
    private let stranger = FaceFrame.faces([.init(score: 0.1, live: true)])

    func testOwnerNeedsTwoLiveMatches() {
        var p = OwnerPresence()
        XCTAssertEqual(p.begin(), .checking)
        XCTAssertNil(p.observe(me, at: at(0)))
        XCTAssertFalse(p.isOwnerPresent(at: at(0)))
        XCTAssertEqual(p.observe(me, at: at(0.2)), .owner)
        XCTAssertTrue(p.isOwnerPresent(at: at(0.2)))
    }

    func testAMatchThatIsNotLiveNeverUnlocks() {
        var p = OwnerPresence(); _ = p.begin()
        for i in 0..<30 { p.observe(.faces([.init(score: 0.9, live: false)]), at: at(Double(i) * 0.2)) }
        XCTAssertEqual(p.state, .checking)
        XCTAssertFalse(p.isOwnerPresent(at: at(6)))
        XCTAssertTrue(p.detail.contains("blink"))
    }

    func testScoreJustUnderTheThresholdIsRejected() {
        var p = OwnerPresence(); _ = p.begin()
        for i in 0..<5 { p.observe(.faces([.init(score: 0.449, live: true)]), at: at(Double(i))) }
        XCTAssertEqual(p.state, .unknown)
    }

    func testUnknownPersonAfterThreeMisses() {
        var p = OwnerPresence(); _ = p.begin()
        XCTAssertNil(p.observe(stranger, at: at(0))); XCTAssertNil(p.observe(stranger, at: at(0.2)))
        XCTAssertEqual(p.observe(stranger, at: at(0.4)), .unknown)
        XCTAssertFalse(p.isOwnerPresent(at: at(0.4)))
    }

    func testNoFaceKeepsOpenUntilTheTimeout() {
        var s = OwnerPresence.Settings(); s.noFaceTimeout = 30
        var p = OwnerPresence(settings: s); _ = p.begin()
        p.observe(me, at: at(0)); p.observe(me, at: at(0.2))
        for i in 0..<3 { p.observe(.faces([]), at: at(1 + Double(i) * 0.2)) }
        XCTAssertEqual(p.state, .noFace)
        XCTAssertTrue(p.isOwnerPresent(at: at(20)), "stepped out of view for a moment")
        XCTAssertFalse(p.isOwnerPresent(at: at(31)), "locked once the timeout passes")
    }

    func testNoFaceWithoutAnEarlierOwnerIsLocked() {
        var p = OwnerPresence(); _ = p.begin()
        for i in 0..<3 { p.observe(.faces([]), at: at(Double(i))) }
        XCTAssertEqual(p.state, .noFace)
        XCTAssertFalse(p.isOwnerPresent(at: at(3)))
    }

    func testAStrangerEndsTheSteppedAwayAllowance() {
        var p = OwnerPresence(); _ = p.begin()
        p.observe(me, at: at(0)); p.observe(me, at: at(0.2))
        for i in 0..<3 { p.observe(stranger, at: at(1 + Double(i) * 0.2)) }
        for i in 0..<3 { p.observe(.faces([]), at: at(2 + Double(i) * 0.2)) }
        XCTAssertEqual(p.state, .noFace)
        XCTAssertFalse(p.isOwnerPresent(at: at(3)), "someone else sat down in between")
    }

    func testAnyFailureLocks() {
        var p = OwnerPresence(); _ = p.begin()
        p.observe(me, at: at(0)); p.observe(me, at: at(0.2))
        XCTAssertEqual(p.observe(.failure("camera unplugged"), at: at(1)), .error)
        XCTAssertFalse(p.isOwnerPresent(at: at(1)))
        for i in 0..<3 { p.observe(.faces([]), at: at(2 + Double(i))) }
        XCTAssertFalse(p.isOwnerPresent(at: at(5)), "a failure also ends the stepped-away allowance")
    }

    func testOwnerWithAGuestBesideThemStillCountsAsOwner() {
        var p = OwnerPresence(); _ = p.begin()
        let both = FaceFrame.faces([.init(score: 0.1, live: false), .init(score: 0.8, live: true)])
        p.observe(both, at: at(0)); p.observe(both, at: at(0.2))
        XCTAssertEqual(p.state, .owner)
    }

    func testCameraOffIsLocked() {
        var p = OwnerPresence(); _ = p.begin()
        p.observe(me, at: at(0)); p.observe(me, at: at(0.2))
        XCTAssertEqual(p.end(), .idle)
        XCTAssertFalse(p.isOwnerPresent(at: at(1)), "every new conversation is checked afresh")
    }
}

final class FaceTemplateTests: XCTestCase {
    private var dir: URL!
    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("face-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    final class KeyBox: @unchecked Sendable { var value: String? }
    private func store(_ box: KeyBox) -> FaceTemplateStore {
        FaceTemplateStore(url: dir.appendingPathComponent("faceprint/face.bin"), readKey: { box.value }, writeKey: { box.value = $0 }, deleteKey: { box.value = nil })
    }

    func testBuildRefusesTooFewOrDisagreeingPictures() {
        XCTAssertThrowsError(try FaceTemplate.build((0..<5).map { _ in vector(score: 1) }, model: "m")) { XCTAssertEqual($0 as? FaceError, .tooFewFrames(5)) }
        var mixed = (0..<19).map { _ in vector(score: 1) }
        mixed.append([0, 0, 1, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try FaceTemplate.build(mixed, model: "m"))
    }

    func testScoreSeparatesOwnerFromOthers() {
        XCTAssertGreaterThan(ownerTemplate.score(vector(score: 0.9)), 0.85)
        XCTAssertLessThan(ownerTemplate.score(vector(score: 0.2)), 0.25)
    }

    func testSavedFileIsEncryptedAndRoundTrips() throws {
        let box = KeyBox(), s = store(box)
        XCTAssertNil(try s.load(), "nothing enrolled")
        try s.save(ownerTemplate)
        XCTAssertNotNil(box.value, "a key was made and handed to the keychain side")
        let raw = try Data(contentsOf: s.url)
        XCTAssertNil(try? JSONSerialization.jsonObject(with: raw), "the file is not readable JSON")
        XCTAssertNil(raw.range(of: Data("embeddings".utf8)))
        XCTAssertEqual(try s.load(), ownerTemplate)
        let perms = try FileManager.default.attributesOfItem(atPath: s.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testWithoutTheKeyOrWithTheWrongKeyItFailsClosed() throws {
        let box = KeyBox(), s = store(box)
        try s.save(ownerTemplate)
        let right = box.value
        box.value = nil
        XCTAssertThrowsError(try s.load()) { XCTAssertEqual($0 as? FaceError, .keyUnavailable) }
        box.value = Data(repeating: 7, count: 32).base64EncodedString()
        XCTAssertThrowsError(try s.load()) { XCTAssertEqual($0 as? FaceError, .templateUnreadable) }
        box.value = right
        XCTAssertNotNil(try s.load())
    }

    func testDeleteRemovesFileAndKey() throws {
        let box = KeyBox(), s = store(box)
        try s.save(ownerTemplate)
        s.delete()
        XCTAssertFalse(s.exists); XCTAssertNil(box.value)
    }

    func testRealModelGivesStableNumbers() throws {
        guard SFaceEmbedder.isInstalled else { throw XCTSkip("face model not installed") }
        let model = try SFaceEmbedder()
        let crop = try XCTUnwrap(SFaceEmbedder.crop(blankImage(), face: face()))
        let a = try model.embed(crop: crop), b = try model.embed(crop: crop)
        XCTAssertEqual(a.count, 128)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Double(a.reduce(0) { $0 + $1 * $1 }), 1, accuracy: 0.001)
    }
}

// MARK: - Watcher and lock, on fakes

private final class FakeFaceCamera: FaceCamera, @unchecked Sendable {
    var onFrame: (@Sendable (CGImage) -> Void)?
    var starts = 0, stops = 0
    var failWith: Error?
    private let lock = NSLock()
    var running: Bool { lock.lock(); defer { lock.unlock() }; return onFrame != nil }
    func start(_ onFrame: @escaping @Sendable (CGImage) -> Void) async throws {
        if let failWith { throw failWith }
        lock.lock(); self.onFrame = onFrame; starts += 1; lock.unlock()
    }
    func stop() { lock.lock(); onFrame = nil; stops += 1; lock.unlock() }
    func push() { lock.lock(); let f = onFrame; lock.unlock(); f?(blankImage(64, 64)) }
}

private final class FakeFaceDetector: FaceDetecting, @unchecked Sendable {
    var faces: [FaceObservation] = []
    var error: Error?
    func detect(in image: CGImage) throws -> [FaceObservation] { if let error { throw error }; return faces }
}

private final class FakeFaceEmbedder: FaceEmbedding, @unchecked Sendable {
    let modelName = "fake"
    var score = 0.9
    func embed(_ image: CGImage, face: FaceObservation) throws -> [Float] { vector(score: score) }
}

final class FaceWatcherTests: XCTestCase {
    private var camera: FakeFaceCamera!
    private var detector: FakeFaceDetector!
    private var embedder: FakeFaceEmbedder!
    private var logURL: URL!

    override func setUp() {
        camera = FakeFaceCamera(); detector = FakeFaceDetector(); embedder = FakeFaceEmbedder()
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("face-\(UUID().uuidString).log")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: logURL) }

    private func watcher(template: @escaping @Sendable () throws -> FaceTemplate? = { ownerTemplate }, liveness: Bool = false) -> FaceWatcher {
        var s = OwnerPresence.Settings(); s.requireLiveness = liveness
        let e = embedder!
        return FaceWatcher(camera: camera, detector: detector, embedder: { e }, template: template, settings: { s }, log: FaceLog(url: logURL))
    }

    /// Pushes frames until the watcher reaches `state` or two seconds pass.
    private func pump(_ w: FaceWatcher, until state: FaceState, mutate: ((Int) -> Void)? = nil) async {
        for i in 0..<200 {
            if w.verdict.state == state { return }
            mutate?(i)
            camera.push()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testOwnerIsRecognisedAndLogged() async throws {
        detector.faces = [face()]
        let w = watcher()
        w.begin("chat")
        await pump(w, until: .owner)
        XCTAssertTrue(w.verdict.ownerPresent)
        w.end("chat")
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(w.verdict.state, .idle)
        XCTAssertFalse(camera.running, "the camera is off once the conversation ends")
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains(" checking")); XCTAssertTrue(log.contains(" owner score=")); XCTAssertTrue(log.contains(" idle"))
        XCTAssertFalse(log.contains("0.0,"), "numbers of the face itself never reach the log")
    }

    func testStrangerIsUnknown() async {
        detector.faces = [face()]; embedder.score = 0.1
        let w = watcher(); w.begin("chat")
        await pump(w, until: .unknown)
        XCTAssertEqual(w.verdict.state, .unknown); XCTAssertFalse(w.verdict.ownerPresent)
        w.end("chat")
    }

    func testAPhotoThatNeverMovesStaysLocked() async {
        detector.faces = [face()]
        let w = watcher(liveness: true); w.begin("chat")
        for _ in 0..<40 { camera.push(); try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(w.verdict.state, .checking); XCTAssertFalse(w.verdict.ownerPresent)
        w.end("chat")
    }

    func testAFaceThatTurnsIsAccepted() async {
        let w = watcher(liveness: true); w.begin("chat")
        let d = detector!
        await pump(w, until: .owner) { i in d.faces = [face(noseX: 140 + CGFloat(i % 30))] }
        XCTAssertTrue(w.verdict.ownerPresent)
        w.end("chat")
    }

    func testCameraFailureLocks() async {
        camera.failWith = VisionError.noCamera
        let w = watcher(); w.begin("chat")
        let v = await w.settledVerdict(wait: 1)
        XCTAssertEqual(v.state, .error); XCTAssertFalse(v.ownerPresent)
        w.end("chat")
    }

    func testDetectorFailureLocks() async {
        detector.error = FaceError.modelFailed("boom")
        let w = watcher(); w.begin("chat")
        await pump(w, until: .error)
        XCTAssertEqual(w.verdict.state, .error)
        w.end("chat")
    }

    func testUnreadableTemplateLocks() async {
        detector.faces = [face()]
        let w = watcher(template: { throw FaceError.keyUnavailable }); w.begin("chat")
        for _ in 0..<10 { camera.push(); try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(w.verdict.state, .error); XCTAssertFalse(w.verdict.ownerPresent)
        w.end("chat")
    }

    func testQuickStartStopNeverLeavesTheCameraOn() async {
        let w = watcher()
        for _ in 0..<20 { w.begin("chat"); w.end("chat") }
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(camera.running)
    }

    func testTwoHoldersShareOneCamera() async {
        detector.faces = [face()]
        let w = watcher(); w.begin("chat"); w.begin("gate")
        await pump(w, until: .owner)
        w.end("gate")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(camera.running, "the conversation still holds it")
        XCTAssertEqual(w.verdict.state, .owner)
        w.end("chat")
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(camera.running)
        XCTAssertEqual(camera.starts, 1)
    }
}

@MainActor
final class OwnerLockTests: XCTestCase {
    private var camera: FakeFaceCamera!
    private var detector: FakeFaceDetector!
    private var embedder: FakeFaceEmbedder!
    private var logURL: URL!
    private var enabled = true, enrolled = true, touchID = false
    private var clock = Date(timeIntervalSince1970: 9_000)
    private var pumping: Task<Void, Never>?

    override func setUp() async throws {
        camera = FakeFaceCamera(); detector = FakeFaceDetector(); embedder = FakeFaceEmbedder()
        detector.faces = [face()]
        enabled = true; enrolled = true; touchID = false
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString).log")
        // A camera that keeps delivering pictures whenever it is on.
        let cam = camera!
        pumping = Task.detached { while !Task.isCancelled { cam.push(); try? await Task.sleep(for: .milliseconds(10)) } }
    }
    override func tearDown() async throws { pumping?.cancel(); try? FileManager.default.removeItem(at: logURL) }

    private func makeLock() -> OwnerLock {
        var s = OwnerPresence.Settings(); s.requireLiveness = false
        let e = embedder!
        let w = FaceWatcher(camera: camera, detector: detector, embedder: { e }, template: { ownerTemplate }, settings: { s }, log: FaceLog(url: logURL))
        return OwnerLock(watcher: w, settings: { [unowned self] in var s = OwnerLock.Settings(); s.enabled = self.enabled; s.decisionSeconds = 1; return s },
                         isEnrolled: { [unowned self] in self.enrolled }, authenticate: { [unowned self] _ in self.touchID },
                         log: FaceLog(url: logURL), now: { [unowned self] in self.clock })
    }

    func testEveryToolIsClassifiedAndPersonalOnesAreNotGeneral() {
        for name in ["email_read", "email_send", "email_search", "calendar_read", "file_read", "file_search", "memory", "memory_search",
                     "contacts", "notion_search", "get_briefing", "run_shell", "computer", "use_skill", "voice_id", "welcome_home", "actions_today"] {
            XCTAssertTrue(OwnerLock.isPersonal(name), name)
        }
        XCTAssertTrue(OwnerLock.isPersonal("a_tool_added_next_year"), "unknown tools are locked by default")
        XCTAssertFalse(OwnerLock.isPersonal("weather")); XCTAssertFalse(OwnerLock.isPersonal("owner_lock"))
    }

    func testOffOrNotEnrolledChangesNothing() async {
        let lock = makeLock()
        embedder.score = 0.1
        enabled = false
        let off = await lock.refusal(tool: "email_read", fromPhone: false)
        XCTAssertNil(off)
        enabled = true; enrolled = false
        let none = await lock.refusal(tool: "email_read", fromPhone: false)
        XCTAssertNil(none)
        XCTAssertEqual(camera.starts, 0, "the camera is never touched while the lock is off")
    }

    func testOwnerPassesStrangerIsRefusedGeneralToolsAlwaysWork() async {
        let lock = makeLock()
        let mine = await lock.refusal(tool: "email_read", fromPhone: false)
        XCTAssertNil(mine)
        embedder.score = 0.1
        let theirs = await lock.refusal(tool: "email_read", fromPhone: false)
        XCTAssertEqual(theirs?.contains("does not recognise"), true)
        let general = await lock.refusal(tool: "weather", fromPhone: false)
        XCTAssertNil(general)
        let locked = await lock.personalDataLocked(fromPhone: false, wait: 1)
        XCTAssertTrue(locked)
    }

    func testNoFaceAndCameraFailureAreRefusedWithTheReason() async {
        let lock = makeLock()
        detector.faces = []
        let empty = await lock.refusal(tool: "calendar_read", fromPhone: false)
        XCTAssertEqual(empty?.contains("cannot see a face"), true)
        detector.error = FaceError.modelFailed("boom")
        let broken = await lock.refusal(tool: "calendar_read", fromPhone: false)
        XCTAssertEqual(broken?.contains("could not run"), true)
    }

    func testPhoneRequestsSkipTheFaceCheck() async {
        let lock = makeLock()
        embedder.score = 0.1
        let r = await lock.refusal(tool: "email_read", fromPhone: true)
        XCTAssertNil(r)
        XCTAssertEqual(camera.starts, 0)
    }

    func testTouchIDOpensItForAWhileAndLockNowClosesIt() async {
        let lock = makeLock()
        embedder.score = 0.1
        let refusedFinger = await lock.unlockWithTouchID()
        XCTAssertFalse(refusedFinger)
        let still = await lock.refusal(tool: "email_read", fromPhone: false)
        XCTAssertNotNil(still)
        touchID = true
        let ok = await lock.unlockWithTouchID()
        XCTAssertTrue(ok)
        let open = await lock.refusal(tool: "email_read", fromPhone: false)
        XCTAssertNil(open)
        clock = clock.addingTimeInterval(11 * 60)
        let expired = await lock.refusal(tool: "email_read", fromPhone: false)
        XCTAssertNotNil(expired, "the unlock runs out by itself")
        _ = await lock.unlockWithTouchID()
        lock.lockNow()
        let closed = await lock.refusal(tool: "email_read", fromPhone: false)
        XCTAssertNotNil(closed)
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("override-on")); XCTAssertTrue(log.contains("override-refused")); XCTAssertTrue(log.contains("locked-by-hand"))
    }

    func testDispatcherRefusesBeforeAskingForApproval() async {
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        let notch = NotchViewModel()
        let actions = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: actions) }
        let d = ToolDispatcher(config: config, context: ToolContext(config: config, modes: ModeManager(config: config, notch: notch), undo: UndoStack(), notch: notch),
                               log: ActionLog(url: actions))
        let send = FakeTool(name: "email_send", tier: .approve), weather = FakeTool(name: "weather", tier: .auto)
        d.register([send, weather])
        var asked = 0
        d.approvalHandler = { _ in asked += 1; return true }
        let lock = makeLock()
        embedder.score = 0.1
        d.ownerGate = { tool, phone in await lock.refusal(tool: tool, fromPhone: phone) }
        let r = await d.call("email_send", input: [:], source: .user)
        XCTAssertTrue(r.isError); XCTAssertTrue(r.content.hasPrefix("Locked"))
        XCTAssertEqual(send.runs, 0); XCTAssertEqual(asked, 0, "no approval is asked for something that cannot happen")
        let w = await d.call("weather", input: [:], source: .user)
        XCTAssertFalse(w.isError)
        // Briefings and timers are checked too: nothing personal is spoken to an empty or unknown room.
        let p = await d.call("email_send", input: [:], source: .proactive)
        XCTAssertTrue(p.content.hasPrefix("Locked"))
        XCTAssertTrue(((try? String(contentsOf: actions, encoding: .utf8)) ?? "").contains("locked"))
    }

    func testToolNeedsTouchIDToChangeTheLock() async throws {
        let lock = makeLock()
        var started = 0, forgot = 0, enabledSet: [Bool] = []
        let tool = OwnerLockTool(lock: lock, hooks: .init(status: { "status" }, isEnrolled: { true }, modelInstalled: { true },
                                                           startEnrollment: { started += 1 }, forget: { forgot += 1 }, setEnabled: { enabledSet.append($0) }))
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        let notch = NotchViewModel()
        let ctx = ToolContext(config: config, modes: ModeManager(config: config, notch: notch), undo: UndoStack(), notch: notch)
        for action in ["enroll", "forget", "off", "unlock"] {
            let r = try await tool.run(input: ["action": action], context: ctx)
            XCTAssertTrue(r.isError, "\(action) without Touch ID")
        }
        XCTAssertEqual(started + forgot + enabledSet.count, 0)
        touchID = true
        for action in ["enroll", "forget", "off", "unlock"] { _ = try await tool.run(input: ["action": action], context: ctx) }
        XCTAssertEqual(started, 1); XCTAssertEqual(forgot, 1); XCTAssertEqual(enabledSet, [false])
        XCTAssertTrue(lock.overrideActive)
    }

    func testGuestPromptLeavesPersonalFactsOut() {
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        let mode = ModeManager(config: config, notch: NotchViewModel()).current
        let normal = SystemPrompt.build(profile: config.profile, mode: mode)
        let guest = SystemPrompt.build(profile: config.profile, mode: mode, guest: true)
        XCTAssertTrue(normal.contains(config.profile.school)); XCTAssertFalse(normal.contains("OWNER LOCK"))
        XCTAssertFalse(guest.contains(config.profile.school)); XCTAssertFalse(guest.contains(config.profile.city))
        XCTAssertTrue(guest.contains("OWNER LOCK"))
        XCTAssertEqual(SystemPrompt.parts(profile: config.profile, mode: mode).stable,
                       SystemPrompt.parts(profile: config.profile, mode: mode, guest: false).stable)
    }

    func testFaceSettingsAreClampedAndSaved() throws {
        var f = FaceConfig(); f.threshold = 0.01; f.decisionSeconds = 999
        XCTAssertEqual(f.presence.threshold, 0.3, "the threshold cannot be set so low that anyone passes")
        XCTAssertEqual(f.lock.decisionSeconds, 15)
        XCTAssertFalse(FaceConfig().enabled, "off until a face is enrolled")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("facecfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: ConfigTests.repoConfigDir.appendingPathComponent("profile.json"), to: dir.appendingPathComponent("profile.json"))
        let store = ConfigStore(directory: dir, env: [:])
        try store.save(faceLockEnabled: true)
        XCTAssertEqual(ConfigStore(directory: dir, env: [:]).profile.face?.enabled, true)
    }
}
