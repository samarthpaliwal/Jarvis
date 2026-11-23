import AVFoundation
import AppKit
import Foundation
import JarvisObjC

public enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case converterUnavailable

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input device is available."
        case .converterUnavailable: return "Could not create an audio format converter."
        }
    }
}

/// Captures the default microphone, resamples to 16 kHz mono Float32, and delivers fixed
/// 80 ms chunks (1280 samples) on a low-priority queue. One capture feeds the wake word
/// detector now and the transcriber in Milestone 3.
///
/// Restarts itself when the input device changes (AirPods connecting, docking) and after sleep.
public final class AudioCapture: @unchecked Sendable {
    public static let sampleRate: Double = 16_000
    /// 80 ms at 16 kHz: the frame size openWakeWord was trained on.
    public static let chunkSize = 1280

    /// Delivered on the capture queue with exactly `chunkSize` samples.
    public var onChunk: (([Float]) -> Void)?
    /// RMS level 0...1 per chunk, on the capture queue.
    public var onLevel: ((Float) -> Void)?
    /// Called on the main queue when the engine restarts or fails.
    public var onStateChange: ((String) -> Void)?

    public private(set) var isRunning = false

    /// Recreated on every restart: after an input-device switch (AirPods ↔ built-in mic) the old
    /// engine can keep reporting the previous device's format and its tap silently stops firing.
    private var engine = AVAudioEngine()
    private var configObserver: Any?
    private var watchdog: Timer?
    /// Last time a chunk was delivered (capture queue writes, main reads; a stale read is harmless).
    private var lastChunkAt = Date()
    public private(set) var restarts = 0
    /// Inference runs here at utility QoS so it lands on efficiency cores. Measured: the same
    /// ~3% in Activity Monitor as a performance core, at lower energy. JARVIS_AUDIO_QOS=userInitiated
    /// moves it to a performance core for experiments.
    private let queue = DispatchQueue(label: "com.samarth.jarvis.audio",
                                      qos: Env.value("JARVIS_AUDIO_QOS") == "userInitiated" ? .userInitiated : .utility)
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate,
                                          channels: 1, interleaved: false)!
    /// Owned by the render thread: built lazily from the format of the buffers that actually arrive.
    private var converter: AVAudioConverter?
    private var pending: [Float] = []
    private var observers: [Any] = []

    /// Restart control (main thread only). Device changes arrive in bursts, so restarts are coalesced,
    /// and failures back off instead of hammering CoreAudio.
    private var restartScheduled = false
    private var failedRestarts = 0
    /// Consecutive watchdog rebuilds that produced no audio. Drives the silence backoff and the "deaf" signal.
    private var silentRebuilds = 0
    public var tuning = Tuning()

    public struct Tuning: Equatable, Sendable {
        /// Wait this long after a device change before rebuilding, so a burst becomes one restart.
        public var restartDebounce: TimeInterval = 0.5
        /// No audio for this long means the tap went silent.
        public var silenceTimeout: TimeInterval = 6
        /// Upper bound for the silence and failure backoff.
        public var maxBackoff: TimeInterval = 60
        /// After this many silent rebuilds in a row, report that the microphone is not delivering audio.
        public var deafAfterRebuilds = 3
        public init() {}
    }

    /// 0.5 s, 1 s, 2 s … capped. Pure so it can be tested.
    public static func backoff(base: TimeInterval, attempt: Int, cap: TimeInterval) -> TimeInterval {
        min(cap, base * pow(2, Double(max(0, min(attempt, 16)))))
    }

    public init() {}

    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start() throws {
        try installTapAndStart()
        if observers.isEmpty { observe() }
        startWatchdog()
    }

    /// If no audio arrives while we think we're running, rebuild the engine. Each rebuild that still
    /// yields nothing doubles the wait, so a dead input device costs one rebuild a minute, not one every 9 s.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.isRunning, !self.restartScheduled else { return }
            let silence = Date().timeIntervalSince(self.lastChunkAt)
            if silence < self.tuning.silenceTimeout {
                if self.silentRebuilds > 0 {
                    JarvisLog.info("Audio watchdog: microphone audio is back after \(self.silentRebuilds) rebuild(s)")
                    if self.silentRebuilds >= self.tuning.deafAfterRebuilds { self.onStateChange?("hearing") }
                    self.silentRebuilds = 0
                }
                return
            }
            let limit = Self.backoff(base: self.tuning.silenceTimeout, attempt: self.silentRebuilds, cap: self.tuning.maxBackoff)
            guard silence > limit else { return }
            self.silentRebuilds += 1
            JarvisLog.warn("Audio watchdog: no microphone audio for \(Int(silence)) s; rebuilding the audio engine (attempt \(self.silentRebuilds))")
            if self.silentRebuilds == self.tuning.deafAfterRebuilds {
                JarvisLog.error("Microphone “\(AudioDeviceInfo.defaultInputDeviceName())” is delivering no audio after \(self.silentRebuilds) rebuilds")
                self.onStateChange?("deaf")
            }
            self.restart(reason: "watchdog: tap went silent")
        }
    }

    public func stop() {
        watchdog?.invalidate()
        watchdog = nil
        teardownEngine()
        isRunning = false
        queue.async { self.pending.removeAll() }
    }

    private func teardownEngine() {
        // AVAudioEngine raises NSException when the device vanished under it; never let that abort the app.
        try? ObjCException.catching { [engine] in
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
    }

    private func installTapAndStart() throws {
        teardownEngine()
        engine = AVAudioEngine()
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.scheduleRestart(reason: "input device changed")
        }
        lastChunkAt = Date()
        let engine = engine
        var inFormat = AVAudioFormat()
        var startError: Error?
        var noDevice = false
        // installTap, inputNode and start can all raise NSException while a device is appearing or
        // disappearing (this crashed the app on 2026-11-22). Catch it and let the caller retry.
        try ObjCException.catching {
            let input = engine.inputNode
            inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { noDevice = true; return }
            input.removeTap(onBus: 0)
            // ~200 ms buffers = 5 render callbacks/s; output is re-chunked to 80 ms below.
            // format nil = "whatever the hardware delivers", so a format that changed between the
            // lines above and here cannot raise a mismatch exception.
            let bufferSize = AVAudioFrameCount(inFormat.sampleRate * 0.2)
            input.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, _ in
                self?.handle(buffer)
            }
            engine.prepare()
            do { try engine.start() } catch { startError = error }
        }
        if noDevice { throw AudioCaptureError.noInputDevice }
        if let startError { throw startError }
        isRunning = true
        JarvisLog.info("Audio capture started on “\(AudioDeviceInfo.defaultInputDeviceName())”: \(Int(inFormat.sampleRate)) Hz, \(inFormat.channelCount) ch → 16 kHz mono; mic permission: \(Self.microphoneStatus.rawValue)")
    }

    /// Runs on the audio render thread: resample, then hand off to our queue.
    private func handle(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buffer.format {
            guard buffer.format.sampleRate > 0, let conv = AVAudioConverter(from: buffer.format, to: outFormat) else { return }
            // Speech-band resampling for a 16 kHz wake word model does not need mastering quality.
            conv.sampleRateConverterQuality = AVAudioQuality.low.rawValue
            conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
            converter = conv
        }
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var served = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if served {
                status.pointee = .noDataNow
                return nil
            }
            served = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        queue.async { [weak self] in self?.enqueue(samples) }
    }

    private func enqueue(_ samples: [Float]) {
        lastChunkAt = Date()
        pending.append(contentsOf: samples)
        while pending.count >= Self.chunkSize {
            let chunk = Array(pending.prefix(Self.chunkSize))
            pending.removeFirst(Self.chunkSize)
            if let onLevel {
                var sum: Float = 0
                for s in chunk { sum += s * s }
                let rms = (sum / Float(chunk.count)).squareRoot()
                // Map typical speech RMS (~0.005–0.15) onto 0...1 with a soft curve for the waveform.
                onLevel(min(1, (rms * 12).squareRoot()))
            }
            onChunk?(chunk)
        }
    }

    private func observe() {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            // Give CoreAudio a moment to bring devices back after sleep.
            self?.scheduleRestart(reason: "wake from sleep", delay: 1.5)
        })
    }

    /// Coalesces bursts of restart requests into one. Main thread.
    private func scheduleRestart(reason: String, delay: TimeInterval? = nil) {
        guard !restartScheduled else { return }
        restartScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? tuning.restartDebounce)) { [weak self] in
            guard let self else { return }
            self.restartScheduled = false
            guard self.watchdog != nil else { return }   // stopped meanwhile
            self.restart(reason: reason)
        }
    }

    private func restart(reason: String) {
        JarvisLog.info("Audio capture restarting (\(reason))")
        restarts += 1
        isRunning = false
        queue.async { self.pending.removeAll() }
        do {
            try installTapAndStart()
            failedRestarts = 0
            onStateChange?("restarted: \(reason)")
        } catch {
            failedRestarts += 1
            let wait = Self.backoff(base: 1, attempt: failedRestarts - 1, cap: tuning.maxBackoff)
            JarvisLog.error("Audio capture restart failed (attempt \(failedRestarts), retrying in \(Int(wait)) s): \(error.localizedDescription)")
            onStateChange?("failed: \(error.localizedDescription)")
            if failedRestarts == tuning.deafAfterRebuilds { onStateChange?("deaf") }
            scheduleRestart(reason: "retry after failure", delay: wait)
        }
    }
}
