import AVFoundation
import Foundation
import Speech

/// Apple's SpeechAnalyzer (macOS 26+): on-device, no Siri/Dictation dependency, downloadable
/// language assets. Preferred over SFSpeechRecognizer when the OS has it.
@available(macOS 26.0, *)
public final class AnalyzerSpeechTranscriber: Transcriber, @unchecked Sendable {
    public let name: String
    public private(set) var isAvailable: Bool = false

    private let locale: Locale
    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate,
                                             channels: 1, interleaved: false)!
    private var generation = 0

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
        name = "Apple SpeechAnalyzer (on-device) \(locale.identifier)"
    }

    /// Downloads the language model if needed. Returns false if the locale is unsupported.
    public func prepare() async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            JarvisLog.warn("SpeechAnalyzer: locale \(locale.identifier) unsupported")
            return false
        }
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                JarvisLog.info("SpeechAnalyzer: downloading \(locale.identifier) speech assets…")
                try await request.downloadAndInstall()
                JarvisLog.info("SpeechAnalyzer: assets installed")
            }
            isAvailable = true
        } catch {
            JarvisLog.error("SpeechAnalyzer asset install failed: \(error.localizedDescription)")
            isAvailable = false
        }
        return isAvailable
    }

    public func requestAuthorization() async -> Bool {
        // SpeechAnalyzer runs on-device and needs no speech-recognition TCC grant; the mic grant is enough.
        if !isAvailable { _ = await prepare() }
        return isAvailable
    }

    public func start(onUpdate: @escaping (TranscriptUpdate) -> Void, onError: @escaping (Error) -> Void) throws {
        guard isAvailable else { throw TranscriberError.unavailable("speech assets not installed") }
        cancel()
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        lock.lock()
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.input = continuation
        lock.unlock()

        resultsTask = Task { [weak self] in
            do {
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                    throw TranscriberError.unavailable("no compatible audio format")
                }
                guard let self else { return }
                self.setAnalyzerFormat(format)
                try await analyzer.start(inputSequence: stream)
                var accumulated = ""
                for try await result in transcriber.results {
                    guard self.isCurrent(gen) else { return }
                    let piece = String(result.text.characters)
                    // Finalized segments accumulate; a volatile result is the in-progress tail.
                    let text = result.isFinal ? (accumulated + piece) : (accumulated + piece)
                    if result.isFinal { accumulated += piece }
                    let update = TranscriptUpdate(text: text.trimmingCharacters(in: .whitespaces), isFinal: false)
                    DispatchQueue.main.async { onUpdate(update) }
                }
                guard self.isCurrent(gen) else { return }
                let final = TranscriptUpdate(text: accumulated.trimmingCharacters(in: .whitespaces), isFinal: true)
                DispatchQueue.main.async { onUpdate(final) }
            } catch is CancellationError {
            } catch {
                guard let self, self.isCurrent(gen) else { return }
                DispatchQueue.main.async { onError(error) }
            }
        }
    }

    private func setAnalyzerFormat(_ format: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        analyzerFormat = format
        converter = AVAudioConverter(from: sourceFormat, to: format)
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }

    public func append(samples: [Float]) {
        lock.lock()
        let continuation = input
        let converter = converter
        let format = analyzerFormat
        lock.unlock()
        guard let continuation, !samples.isEmpty,
              let src = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        src.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in src.floatChannelData![0].update(from: p.baseAddress!, count: samples.count) }

        guard let format, let converter, format != sourceFormat else {
            continuation.yield(AnalyzerInput(buffer: src))
            return
        }
        let ratio = format.sampleRate / sourceFormat.sampleRate
        guard let dst = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(samples.count) * ratio) + 32) else { return }
        var served = false
        var error: NSError?
        converter.convert(to: dst, error: &error) { _, status in
            if served { status.pointee = .noDataNow; return nil }
            served = true
            status.pointee = .haveData
            return src
        }
        if error == nil, dst.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: dst))
        }
    }

    public func finish() {
        lock.lock()
        let continuation = input
        let analyzer = analyzer
        input = nil
        lock.unlock()
        continuation?.finish()
        Task { try? await analyzer?.finalizeAndFinishThroughEndOfInput() }
    }

    public func cancel() {
        lock.lock()
        generation += 1
        let continuation = input
        let analyzer = analyzer
        let task = resultsTask
        input = nil
        self.analyzer = nil
        transcriber = nil
        resultsTask = nil
        lock.unlock()
        continuation?.finish()
        task?.cancel()
        Task { await analyzer?.cancelAndFinishNow() }
    }
}

/// Picks SpeechAnalyzer on macOS 26+, else SFSpeechRecognizer.
public enum TranscriberFactory {
    public static func make(locale: Locale) -> Transcriber {
        if #available(macOS 26.0, *), ProcessInfo.processInfo.environment["JARVIS_FORCE_SFSPEECH"] != "1" {
            return AnalyzerSpeechTranscriber(locale: locale)
        }
        return AppleSpeechTranscriber(locale: locale)
    }
}
