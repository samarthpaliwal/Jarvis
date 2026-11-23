import CoreGraphics
import Foundation

/// The guided setup: about 25 pictures of the owner's face at different angles, turned into numbers on the
/// spot. The pictures are never written anywhere; only the numbers are kept, encrypted.
@MainActor
public final class FaceEnrollment {
    public static let poses = [
        ("Look straight at the camera.", "Straight ahead"),
        ("Turn your head a little to the left.", "A little left"),
        ("Now a little to the right.", "A little right"),
        ("Tilt your chin up slightly.", "Chin up"),
        ("And down slightly.", "Chin down"),
    ]

    public enum Outcome: Equatable {
        case enrolled(frames: Int, consistency: Double)
        case busy
        case failed(String)
    }

    private let watcher: FaceWatcher
    private let store: FaceTemplateStore
    private weak var host: (any EnrollmentHost)?
    public var framesPerPose = 5
    public var secondsPerPose: TimeInterval = 7
    /// Pictures closer together than this are too alike to be worth keeping.
    public var spacing: TimeInterval = 0.3

    public init(watcher: FaceWatcher, store: FaceTemplateStore, host: any EnrollmentHost) {
        self.watcher = watcher; self.store = store; self.host = host
    }

    /// Collects embeddings from the watcher's frames. One face only, big enough to read.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private let embedder: any FaceEmbedding
        private var wanted = 0
        private var lastAt = Date.distantPast
        private var liveness = LivenessTracker()
        private(set) var embeddings: [[Float]] = []
        private(set) var sawSeveralFaces = false
        let spacing: TimeInterval
        init(embedder: any FaceEmbedding, spacing: TimeInterval) { self.embedder = embedder; self.spacing = spacing }

        func want(_ n: Int) { lock.lock(); wanted = n; lock.unlock() }
        var remaining: Int { lock.lock(); defer { lock.unlock() }; return wanted }
        var count: Int { lock.lock(); defer { lock.unlock() }; return embeddings.count }
        private var everLive = false
        /// True once a blink or a head turn was seen at any point during the setup.
        var isLive: Bool { lock.lock(); defer { lock.unlock() }; return everLive }
        func take() -> [[Float]] { lock.lock(); defer { embeddings = []; lock.unlock() }; return embeddings }

        func see(_ image: CGImage, _ faces: [FaceObservation], at now: Date = Date()) {
            if faces.count > 1 { lock.lock(); sawSeveralFaces = true; lock.unlock(); return }
            guard let face = faces.first, face.eyeDistance >= 40 else { return }
            lock.lock()
            if liveness.add(openness: face.eyeOpenness, noseOffset: face.noseOffset, at: now) { everLive = true }
            let due = wanted > 0 && now.timeIntervalSince(lastAt) >= spacing
            lock.unlock()
            guard due, let e = try? embedder.embed(image, face: face) else { return }
            lock.lock(); embeddings.append(e); wanted -= 1; lastAt = now; lock.unlock()
        }
    }

    public func run() async -> Outcome {
        guard let host else { return .failed("not available") }
        let embedder: any FaceEmbedding
        do { embedder = try watcher.makeEmbedder() } catch { return .failed(error.localizedDescription) }
        guard host.beginEnrollment() else { return .busy }
        defer { host.endEnrollment() }

        let collector = Collector(embedder: embedder, spacing: spacing)
        watcher.frameObserver = { image, faces in collector.see(image, faces) }
        watcher.begin("enroll")
        defer { watcher.frameObserver = nil; watcher.end("enroll") }

        await host.say("Let's set up face recognition. Sit where you normally sit, with light on your face, and follow five short steps. No photos are saved.")
        for (i, pose) in Self.poses.enumerated() {
            host.show(title: "Face setup \(i + 1) of \(Self.poses.count)", text: pose.1)
            await host.say(pose.0)
            collector.want(framesPerPose)
            let deadline = Date().addingTimeInterval(secondsPerPose)
            while collector.remaining > 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            collector.want(0)
        }
        let embeddings = collector.take()
        host.show(title: "Face setup", text: "Working it out…")
        guard collector.isLive else {
            await host.say("I couldn't confirm a live face: I never saw a blink or a head turn. Nothing was saved. Try again with more light.")
            return .failed("no sign of life during enrollment")
        }
        do {
            // Drop the odd picture that does not agree with the rest (a hand over the face, a blur).
            let rough = FaceMath.centroid(embeddings)
            let kept = embeddings.filter { FaceMath.cosine($0, rough) >= 0.4 }
            let template = try FaceTemplate.build(kept, model: embedder.modelName)
            store.delete()                    // a new face gets a new key; the old data is gone either way
            try store.save(template)
            JarvisLog.info(String(format: "Face: enrolled from %d pictures, consistency %.2f (lowest %.2f)", kept.count, template.selfScoreMean, template.selfScoreMin))
            host.show(title: "Face recognition is on", text: "\(kept.count) pictures measured. Only the numbers are kept, encrypted on this Mac.")
            await host.say("Face recognition is set up. From now on your email, calendar, files and memory only open when I can see it's you.")
            return .enrolled(frames: kept.count, consistency: template.selfScoreMean)
        } catch {
            JarvisLog.warn("Face: enrollment failed: \(error.localizedDescription)")
            let extra = collector.sawSeveralFaces ? " I saw more than one face at times; try again alone in the picture." : " Try again with more light, closer to the camera."
            await host.say("\(error.localizedDescription) Nothing was saved.\(extra)")
            return .failed(error.localizedDescription)
        }
    }
}
