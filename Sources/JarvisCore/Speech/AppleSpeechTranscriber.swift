import AVFoundation
import Foundation
import Speech

/// Apple's `SFSpeechRecognizer`, forced on-device when the locale supports it.
/// Falls back to Apple's server recognition (and logs it) only if on-device is unsupported.
public final class AppleSpeechTranscriber: NSObject, Transcriber, @unchecked Sendable {
    public let name: String
    public private(set) var isAvailable: Bool = false

    private let recognizer: SFSpeechRecognizer?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate,
                                       channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onUpdate: ((TranscriptUpdate) -> Void)?
    private var onError: ((Error) -> Void)?
    private var finished = false

    public init(locale: Locale = Locale(identifier: "en-US")) {
        recognizer = SFSpeechRecognizer(locale: locale)
        let onDevice = recognizer?.supportsOnDeviceRecognition ?? false
        name = "Apple SFSpeechRecognizer (\(onDevice ? "on-device" : "server")) \(locale.identifier)"
        super.init()
        isAvailable = recognizer?.isAvailable ?? false
        recognizer?.delegate = self
    }

    public func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    public func start(onUpdate: @escaping (TranscriptUpdate) -> Void, onError: @escaping (Error) -> Void) throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw TranscriberError.notAuthorized }
        guard let recognizer, recognizer.isAvailable else { throw TranscriberError.unavailable("recognizer not available for locale") }
        cancel()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        req.addsPunctuation = true
        req.taskHint = .dictation
        if !recognizer.supportsOnDeviceRecognition {
            JarvisLog.warn("On-device speech recognition unsupported for this locale; using Apple's server")
        }
        lock.lock()
        self.request = req
        self.onUpdate = onUpdate
        self.onError = onError
        self.finished = false
        lock.unlock()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.lock.lock()
            let update = self.onUpdate
            let fail = self.onError
            let alreadyFinished = self.finished
            if let result, result.isFinal { self.finished = true }
            self.lock.unlock()
            if alreadyFinished { return }
            if let result {
                let u = TranscriptUpdate(text: result.bestTranscription.formattedString, isFinal: result.isFinal)
                DispatchQueue.main.async { update?(u) }
            } else if let error {
                // Cancellation and "no speech" after endAudio are normal; surface the rest.
                let ns = error as NSError
                let benign = ns.domain == "kAFAssistantErrorDomain" && (ns.code == 216 || ns.code == 1110 || ns.code == 203)
                if !benign {
                    DispatchQueue.main.async { fail?(error) }
                }
            }
        }
    }

    public func append(samples: [Float]) {
        lock.lock()
        let req = request
        lock.unlock()
        guard let req, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        req.append(buffer)
    }

    public func finish() {
        lock.lock()
        let req = request
        lock.unlock()
        req?.endAudio()
    }

    public func cancel() {
        lock.lock()
        finished = true
        let t = task
        let r = request
        task = nil
        request = nil
        onUpdate = nil
        onError = nil
        lock.unlock()
        r?.endAudio()
        t?.cancel()
    }
}

extension AppleSpeechTranscriber: SFSpeechRecognizerDelegate {
    public func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        isAvailable = available
        JarvisLog.info("Speech recognizer availability: \(available)")
    }
}
