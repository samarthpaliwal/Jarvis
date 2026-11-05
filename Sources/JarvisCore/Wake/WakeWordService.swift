import Foundation
import Combine

/// Owns the microphone capture + detector and publishes state for the UI.
/// Detection work happens on the capture queue; everything published is main-actor.
@MainActor
public final class WakeWordService: ObservableObject {
    public enum State: Equatable {
        case stopped, starting, listening, paused, micDenied
        case failed(String)

        public var label: String {
            switch self {
            case .stopped: return "off"
            case .starting: return "starting"
            case .listening: return "listening for “Hey Jarvis”"
            case .paused: return "paused"
            case .micDenied: return "microphone access denied"
            case .failed(let msg): return "failed: \(msg)"
            }
        }
    }

    public struct Stats: Equatable {
        public var chunks: Int = 0
        public var detections: Int = 0
        public var averageInferenceMs: Double = 0
        public var peakScore: Float = 0
    }

    @Published public private(set) var state: State = .stopped
    @Published public private(set) var stats = Stats()
    @Published public private(set) var lastScore: Float = 0

    /// Fired on the main actor when the wake phrase is heard. The date is the moment of detection.
    public var onWake: ((Date) -> Void)?
    /// Audio level 0...1 at ~12 Hz, main actor. Drives the waveform.
    public var onLevel: ((Float) -> Void)?
    /// Every 80 ms chunk, on the capture queue, regardless of pause state. Feeds the transcriber.
    public nonisolated(unsafe) var audioTap: (([Float]) -> Void)?

    public let capture = AudioCapture()
    private let runner = Runner()
    private var detectorFactory: () throws -> WakeWordDetector

    public init(detectorFactory: @escaping () throws -> WakeWordDetector = { try OpenWakeWordDetector.bundled() }) {
        self.detectorFactory = detectorFactory
        capture.onChunk = { [weak self, runner] chunk in
            self?.audioTap?(chunk)
            runner.process(chunk)
        }
        capture.onLevel = { [weak self, runner] level in
            runner.noteLevel(level)
            DispatchQueue.main.async { self?.onLevel?(level) }
        }
        capture.onStateChange = { [weak self] msg in
            Task { @MainActor in
                self?.runner.reset()
                if msg.hasPrefix("failed") { self?.state = .failed(msg) }
            }
        }
        runner.onDetection = { [weak self] date in
            DispatchQueue.main.async { self?.handleDetection(at: date) }
        }
        runner.onStats = { [weak self] stats, score in
            DispatchQueue.main.async {
                self?.stats = stats
                self?.lastScore = score
            }
        }
    }

    public func start() async {
        guard state != .listening, state != .starting else { return }
        state = .starting
        guard await AudioCapture.requestMicrophoneAccess() else {
            state = .micDenied
            JarvisLog.warn("Microphone access denied; wake word disabled")
            return
        }
        do {
            if runner.detector == nil {
                let det = try detectorFactory()
                if let oww = det as? OpenWakeWordDetector,
                   let b = ProcessInfo.processInfo.environment["JARVIS_WAKE_BATCH"].flatMap(Int.init) {
                    oww.batchSize = b
                }
                runner.detector = det
            }
            try capture.start()
            // JARVIS_WAKE_PAUSED=1 keeps the mic open but skips inference (used for CPU baselines).
            runner.isPaused = ProcessInfo.processInfo.environment["JARVIS_WAKE_PAUSED"] == "1"
            state = runner.isPaused ? .paused : .listening
        } catch {
            state = .failed(error.localizedDescription)
            JarvisLog.error("Wake word start failed: \(error.localizedDescription)")
        }
    }

    public func stop() {
        capture.stop()
        runner.reset()
        state = .stopped
        JarvisLog.info("Wake word stopped")
    }

    /// Keep the mic open but ignore scores (used while Jarvis itself is transcribing).
    public func setPaused(_ paused: Bool) {
        guard state == .listening || state == .paused else { return }
        runner.isPaused = paused
        if paused { runner.reset() }
        state = paused ? .paused : .listening
    }

    /// For testing without a microphone: behaves exactly like a real detection.
    public func simulateWake() {
        handleDetection(at: Date())
    }

    private func handleDetection(at date: Date) {
        stats.detections += 1
        JarvisLog.info("Wake word detected (score \(String(format: "%.2f", runner.lastScore)))")
        onWake?(date)
    }

    public var threshold: Float {
        get { runner.detector?.threshold ?? 0.5 }
        set { runner.detector?.threshold = newValue }
    }

    /// All mutable detection state lives here and is only touched on the capture queue.
    final class Runner: @unchecked Sendable {
        var detector: WakeWordDetector?
        var isPaused = false
        var onDetection: ((Date) -> Void)?
        var onStats: ((Stats, Float) -> Void)?
        private(set) var lastScore: Float = 0

        private var cooldownUntil = Date.distantPast
        private var stats = Stats()
        private var inferenceTotal: Double = 0
        private let cooldown: TimeInterval = 2.0
        /// `JARVIS_WAKE_DEBUG=1` logs every score ≥ 0.1.
        private let debugScores = ProcessInfo.processInfo.environment["JARVIS_WAKE_DEBUG"] == "1"

        func process(_ chunk: [Float]) {
            guard let detector, !isPaused else { return }
            do {
                let score = try detector.process(chunk: chunk)
                lastScore = score
                stats.chunks += 1
                if let oww = detector as? OpenWakeWordDetector, stats.chunks % max(1, oww.batchSize) == 0 {
                    inferenceTotal += oww.lastInferenceMillis
                    stats.averageInferenceMs = inferenceTotal / Double(stats.chunks)
                }
                stats.peakScore = max(stats.peakScore, score)
                let now = Date()
                if score >= detector.threshold, now >= cooldownUntil {
                    cooldownUntil = now.addingTimeInterval(cooldown)
                    stats.detections += 1
                    detector.reset()
                    onDetection?(now)
                }
                if stats.chunks % 25 == 0 || score >= detector.threshold {
                    onStats?(stats, score)
                }
                if debugScores, score >= 0.1 {
                    JarvisLog.info(String(format: "wake score %.2f", score))
                }
                if stats.chunks % 750 == 0 { // every minute
                    JarvisLog.info(String(format: "wake stats: %d chunks, %.2f ms/chunk avg, peak %.2f, %d detections",
                                          stats.chunks, stats.averageInferenceMs, stats.peakScore, stats.detections))
                }
            } catch {
                JarvisLog.error("Wake word inference failed: \(error.localizedDescription)")
            }
        }

        private var levelPeak: Float = 0
        private var levelCount = 0
        func noteLevel(_ level: Float) {
            levelPeak = max(levelPeak, level)
            levelCount += 1
            if debugScores, levelCount % 25 == 0 {
                JarvisLog.info(String(format: "mic level peak (2 s) %.3f", levelPeak))
                levelPeak = 0
            }
        }

        func reset() {
            detector?.reset()
            cooldownUntil = .distantPast
        }
    }
}
