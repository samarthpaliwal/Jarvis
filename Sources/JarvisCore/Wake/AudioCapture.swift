import AVFoundation
import AppKit
import Foundation

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

    private let engine = AVAudioEngine()
    /// Inference runs here at utility QoS so it lands on efficiency cores. Measured: the same
    /// ~3% in Activity Monitor as a performance core, at lower energy. JARVIS_AUDIO_QOS=userInitiated
    /// moves it to a performance core for experiments.
    private let queue = DispatchQueue(label: "com.samarth.jarvis.audio",
                                      qos: ProcessInfo.processInfo.environment["JARVIS_AUDIO_QOS"] == "userInitiated" ? .userInitiated : .utility)
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate,
                                          channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var pending: [Float] = []
    private var observers: [Any] = []

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
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        queue.async { self.pending.removeAll() }
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw AudioCaptureError.noInputDevice }
        guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else { throw AudioCaptureError.converterUnavailable }
        // Speech-band resampling for a 16 kHz wake word model does not need mastering quality.
        conv.sampleRateConverterQuality = AVAudioQuality.low.rawValue
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        converter = conv
        input.removeTap(onBus: 0)
        // ~200 ms buffers = 5 render callbacks/s; output is re-chunked to 80 ms below.
        let bufferSize = AVAudioFrameCount(inFormat.sampleRate * 0.2)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        JarvisLog.info("Audio capture started on “\(AudioDeviceInfo.defaultInputDeviceName())”: \(Int(inFormat.sampleRate)) Hz, \(inFormat.channelCount) ch → 16 kHz mono; mic permission: \(Self.microphoneStatus.rawValue)")
    }

    /// Runs on the audio render thread: resample, then hand off to our queue.
    private func handle(_ buffer: AVAudioPCMBuffer) {
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
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart(reason: "input device changed")
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            // Give CoreAudio a moment to bring devices back after sleep.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.restart(reason: "wake from sleep") }
        })
    }

    private func restart(reason: String) {
        JarvisLog.info("Audio capture restarting (\(reason))")
        stop()
        do {
            try installTapAndStart()
            onStateChange?("restarted: \(reason)")
        } catch {
            JarvisLog.error("Audio capture restart failed: \(error.localizedDescription)")
            onStateChange?("failed: \(error.localizedDescription)")
        }
    }
}
