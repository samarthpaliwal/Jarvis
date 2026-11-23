import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Something that delivers camera pictures while it is running.
public protocol FaceCamera: AnyObject, Sendable {
    func start(_ onFrame: @escaping @Sendable (CGImage) -> Void) async throws
    func stop()
}

/// The Mac's camera, throttled to a few pictures a second and shrunk before anything looks at them.
public final class LiveFaceCamera: FaceCamera, @unchecked Sendable {
    private let session: CameraSession
    private let ci = CIContext()
    private let lock = NSLock()
    private var lastAt = Date.distantPast
    public var framesPerSecond: Double = 6
    public var maxSide: CGFloat = 720
    static let holder = "face"

    public init(session: CameraSession) { self.session = session }

    public func start(_ onFrame: @escaping @Sendable (CGImage) -> Void) async throws {
        try await session.acquire(Self.holder)
        session.setFrameTap(Self.holder) { [weak self] pixels in
            guard let self else { return }
            let now = Date()
            self.lock.lock()
            let due = now.timeIntervalSince(self.lastAt) >= 1 / max(1, self.framesPerSecond)
            if due { self.lastAt = now }
            self.lock.unlock()
            guard due else { return }
            var image = CIImage(cvPixelBuffer: pixels)
            let side = max(image.extent.width, image.extent.height)
            if side > self.maxSide { image = image.transformed(by: CGAffineTransform(scaleX: self.maxSide / side, y: self.maxSide / side)) }
            guard let cg = self.ci.createCGImage(image, from: image.extent) else { return }
            onFrame(cg)
        }
    }

    public func stop() {
        session.setFrameTap(Self.holder, nil)
        session.release(Self.holder)
    }
}

/// Every change of face state, with a timestamp: ~/Library/Logs/Jarvis/face.log. Scores and reasons only;
/// never a picture, never the face numbers.
public final class FaceLog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    public init(url: URL = JarvisLog.logDirectory.appendingPathComponent("face.log")) { self.url = url }

    public func record(_ event: String, detail: String = "", score: Double? = nil, at date: Date = Date()) {
        var line = ISO8601DateFormatter().string(from: date) + " " + event
        if let score { line += String(format: " score=%.2f", score) }
        if !detail.isEmpty { line += " " + detail }
        line += "\n"
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

/// Watches the camera while a conversation is open and keeps the current face state.
/// Anything that goes wrong (camera, model, key, template) ends in `.error`, which is locked.
public final class FaceWatcher: @unchecked Sendable {
    public struct Verdict: Equatable, Sendable {
        public var state: FaceState
        public var ownerPresent: Bool
        public var detail: String
        public var score: Double?
    }

    private let camera: any FaceCamera
    private let detector: any FaceDetecting
    private let embedder: @Sendable () throws -> any FaceEmbedding
    private let template: @Sendable () throws -> FaceTemplate?
    private let log: FaceLog
    private let now: @Sendable () -> Date
    private let work = DispatchQueue(label: "com.samarth.jarvis.face")
    private let lock = NSLock()

    // Guarded by `lock`.
    private var presence: OwnerPresence
    private var liveness = LivenessTracker()
    private var holders = Set<String>()
    private var enrolled: FaceTemplate?
    private var generation = 0
    private var busy = false

    public var settings: @Sendable () -> OwnerPresence.Settings
    public var onChange: (@Sendable (FaceState, String) -> Void)?
    /// For enrollment: every picture with the faces found in it (called off the main thread).
    public var frameObserver: (@Sendable (CGImage, [FaceObservation]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return observer }
        set { lock.lock(); observer = newValue; lock.unlock() }
    }
    private var observer: (@Sendable (CGImage, [FaceObservation]) -> Void)?

    public init(camera: any FaceCamera, detector: any FaceDetecting = VisionFaceDetector(),
                embedder: @escaping @Sendable () throws -> any FaceEmbedding,
                template: @escaping @Sendable () throws -> FaceTemplate?,
                settings: @escaping @Sendable () -> OwnerPresence.Settings = { OwnerPresence.Settings() },
                log: FaceLog = FaceLog(), now: @escaping @Sendable () -> Date = Date.init) {
        self.camera = camera; self.detector = detector; self.embedder = embedder; self.template = template
        self.settings = settings; self.log = log; self.now = now
        self.presence = OwnerPresence(settings: settings())
    }

    public var verdict: Verdict {
        lock.lock(); defer { lock.unlock() }
        return Verdict(state: presence.state, ownerPresent: presence.isOwnerPresent(at: now()), detail: presence.detail, score: presence.lastScore)
    }
    public var isWatching: Bool { lock.lock(); defer { lock.unlock() }; return !holders.isEmpty }
    public func makeEmbedder() throws -> any FaceEmbedding { try embedder() }

    /// Start looking (or keep looking). Each caller names itself and must call `end` with the same name.
    public func begin(_ holder: String) {
        lock.lock()
        let first = holders.isEmpty
        holders.insert(holder)
        guard first else { lock.unlock(); return }
        generation += 1
        let mine = generation
        presence.settings = settings()
        liveness.reset()
        var change = presence.begin()
        do { enrolled = try template() } catch {
            enrolled = nil
            change = presence.observe(.failure(error.localizedDescription), at: now()) ?? change
        }
        let detail = presence.detail
        lock.unlock()
        if let change { report(change, detail, nil) }
        enqueue { [weak self] in
            guard let self else { return }
            guard self.isCurrent(mine) else { return }                 // ended before the camera even started
            do {
                try await self.camera.start { [weak self] image in self?.work.async { self?.process(image, generation: mine) } }
            } catch {
                self.apply(.failure("camera: \(error.localizedDescription)"), generation: mine)
            }
        }
    }

    private func isCurrent(_ mine: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == mine }

    /// Camera starts and stops run strictly one after another, in the order they were asked for, so a
    /// quick start-then-stop can never leave the camera on.
    private var chain: Task<Void, Never>?
    private func enqueue(_ step: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = chain
        chain = Task { await previous?.value; await step() }
        lock.unlock()
    }

    public func end(_ holder: String) {
        lock.lock()
        holders.remove(holder)
        guard holders.isEmpty else { lock.unlock(); return }
        generation += 1
        let change = presence.end()
        let detail = presence.detail
        lock.unlock()
        enqueue { [weak self] in self?.camera.stop() }
        if let change { report(change, detail, nil) }
    }

    /// Forget that the owner was seen: the next check starts from nothing.
    public func forgetOwner() { lock.lock(); presence.forgetOwner(); lock.unlock() }

    /// The verdict once the first moments of looking are over, or after `wait` seconds at the latest.
    public func settledVerdict(wait: TimeInterval) async -> Verdict {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            let v = verdict
            if v.ownerPresent || (v.state != .checking && v.state != .idle) || Date() >= deadline { return v }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private func process(_ image: CGImage, generation mine: Int) {
        lock.lock()
        let current = generation == mine && !holders.isEmpty
        let template = enrolled
        let observer = observer
        if current, busy { lock.unlock(); return }        // still on the last picture: skip this one
        if current { busy = true }
        lock.unlock()
        guard current else { return }
        defer { lock.lock(); busy = false; lock.unlock() }
        do {
            let found = try detector.detect(in: image)
            observer?(image, found)
            guard let template else { return }             // not enrolled: the state stays at its error
            let model = try embedder()
            // The three biggest faces are plenty; a crowd in the background is not worth the time.
            let faces = found.sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height }.prefix(3)
            var scored: [(face: FaceObservation, score: Double)] = []
            for f in faces {
                guard let e = try? model.embed(image, face: f) else { continue }      // too small to read: not a match
                scored.append((f, template.score(e)))
            }
            let at = now()
            lock.lock()
            var live = false
            if let best = scored.max(by: { $0.score < $1.score }) {
                live = liveness.add(openness: best.face.eyeOpenness, noseOffset: best.face.noseOffset, at: at)
            }
            let top = scored.map(\.score).max()
            lock.unlock()
            // Faces that could not be read still count as "someone is there".
            var frame = scored.map { FaceFrame.Face(score: $0.score, live: $0.score == top && live) }
            if frame.isEmpty, !found.isEmpty { frame = [FaceFrame.Face(score: -1, live: false)] }
            apply(.faces(frame), generation: mine)
        } catch {
            apply(.failure(error.localizedDescription), generation: mine)
        }
    }

    private func apply(_ frame: FaceFrame, generation mine: Int) {
        lock.lock()
        guard generation == mine, !holders.isEmpty else { lock.unlock(); return }
        let change = presence.observe(frame, at: now())
        let detail = presence.detail, score = presence.lastScore
        lock.unlock()
        if let change { report(change, detail, score) }
    }

    private func report(_ state: FaceState, _ detail: String, _ score: Double?) {
        log.record(state.rawValue, detail: detail, score: score, at: now())
        onChange?(state, detail)
    }
}
