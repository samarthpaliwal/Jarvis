import AVFoundation
import Foundation

/// Text-to-speech behind one surface so a better TTS (ElevenLabs, Kokoro, …) can replace Apple later.
public protocol SpeechOutput: AnyObject {
    var name: String { get }
    var isSpeaking: Bool { get }
    /// Speak `text`; `onFinished(true)` when it completed, `onFinished(false)` when stopped early. Main queue.
    func speak(_ text: String, volume: Float, rate: Float, onFinished: @escaping (Bool) -> Void)
    /// Queue a sentence behind whatever is playing (streaming replies). No per-sentence callback.
    func enqueue(_ text: String, volume: Float, rate: Float)
    /// Called once everything queued has finished (true) or was stopped (false).
    func whenQueueDrained(_ onFinished: @escaping (Bool) -> Void)
    /// Stop immediately (barge-in).
    func stop()
}

/// Picks the best installed system voice. Premium > Enhanced > Default, English first.
public enum VoicePicker {
    public struct Candidate: Equatable {
        public var identifier: String
        public var name: String
        public var language: String
        public var quality: AVSpeechSynthesisVoiceQuality
    }

    /// Natural-sounding default voices, in order of preference, when nothing better is installed.
    /// JARVIS is British: en-GB voices first (Jamie, Oliver, Daniel, Serena, Kate), then the natural US ones.
    static let preferredNames = ["Jamie", "Oliver", "Daniel", "Serena", "Kate", "Stephanie", "Ava", "Zoe", "Evan", "Nathan", "Samantha", "Alex", "Karen", "Moira", "Tessa", "Fiona"]

    /// Apple's Siri neural voices (identifier com.apple.siri.natural.*) are by far the smoothest on-device voices.
    static func isSiriNatural(_ identifier: String) -> Bool { identifier.contains(".siri.") }

    /// Higher is better: Siri neural 4, Premium 3, Enhanced 2, Default 1 (novelty voices last).
    static func rank(_ c: Candidate) -> Int {
        if isNovelty(c.identifier) { return 0 }
        if isSiriNatural(c.identifier) { return 4 }
        return c.quality.rawValue
    }

    /// Novelty / legacy voices live under this prefix (Albert, Bubbles, Cellos, …).
    static func isNovelty(_ identifier: String) -> Bool {
        identifier.hasPrefix("com.apple.speech.synthesis.voice.")
    }

    public static func candidates(languagePrefix: String = "en") -> [Candidate] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(languagePrefix) }
            .map { Candidate(identifier: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality) }
            .sorted { a, b in
                if rank(a) != rank(b) { return rank(a) > rank(b) }
                let aGB = a.language == "en-GB", bGB = b.language == "en-GB"
                if aGB != bGB { return aGB }
                let ai = preferredNames.firstIndex(of: a.name) ?? Int.max
                let bi = preferredNames.firstIndex(of: b.name) ?? Int.max
                if ai != bi { return ai < bi }
                let aUS = a.language == "en-US", bUS = b.language == "en-US"
                if aUS != bUS { return aUS }
                return a.name < b.name
            }
    }

    /// `preferred` wins when installed; otherwise the highest-quality English voice.
    public static func best(preferred identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let v = AVSpeechSynthesisVoice(identifier: identifier) { return v }
        if let top = candidates().first { return AVSpeechSynthesisVoice(identifier: top.identifier) }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    public static func label(_ c: Candidate) -> String {
        isSiriNatural(c.identifier) ? "Siri neural" : label(c.quality)
    }

    /// True when the saved choice is a plain default voice and something clearly better is installed.
    public static func shouldUpgrade(saved identifier: String?) -> Bool {
        guard let identifier, let v = AVSpeechSynthesisVoice(identifier: identifier) else { return false }
        let saved = Candidate(identifier: v.identifier, name: v.name, language: v.language, quality: v.quality)
        guard let best = candidates().first else { return false }
        return rank(best) > rank(saved) && rank(saved) <= 1
    }

    public static func label(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }
}

/// AVSpeechSynthesizer with the best available voice.
public final class AppleSpeechOutput: NSObject, SpeechOutput, AVSpeechSynthesizerDelegate {
    public var name: String { "AVSpeechSynthesizer · \(voice?.name ?? "default") (\(voice.map { VoicePicker.label($0.quality) } ?? "-"))" }
    public var isSpeaking: Bool { synthesizer.isSpeaking }
    public var voice: AVSpeechSynthesisVoice?

    private let synthesizer = AVSpeechSynthesizer()
    private var completion: ((Bool) -> Void)?
    private var pending = 0

    public init(preferredVoice identifier: String?) {
        super.init()
        voice = VoicePicker.best(preferred: identifier)
        synthesizer.delegate = self
    }

    private func utterance(_ text: String, volume: Float, rate: Float) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.volume = max(0, min(1, volume))
        u.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, rate))
        u.prefersAssistiveTechnologySettings = false
        return u
    }

    public func speak(_ text: String, volume: Float, rate: Float, onFinished: @escaping (Bool) -> Void) {
        stop()
        completion = onFinished
        pending = 1
        synthesizer.speak(utterance(text, volume: volume, rate: rate))
    }

    public func enqueue(_ text: String, volume: Float, rate: Float) {
        pending += 1
        synthesizer.speak(utterance(text, volume: volume, rate: rate))
    }

    public func whenQueueDrained(_ onFinished: @escaping (Bool) -> Void) {
        if pending == 0 { DispatchQueue.main.async { onFinished(true) } } else { completion = onFinished }
    }

    public func stop() {
        pending = 0
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        } else if let done = completion {
            completion = nil
            DispatchQueue.main.async { done(false) }
        }
    }

    private func finished(_ completed: Bool) {
        pending = max(0, pending - 1)
        if !completed { pending = 0 }
        guard pending == 0, let done = completion else { return }
        completion = nil
        DispatchQueue.main.async { done(completed) }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished(true)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finished(false)
    }
}
