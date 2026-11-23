import Foundation

/// Decides when the user has finished talking. Pure logic, fed by transcript updates and time.
public struct Endpointer: Equatable {
    public enum Reason: String, Equatable {
        case silenceAfterSpeech, noSpeech, maxDuration, finalResult
    }

    public struct Settings: Equatable {
        /// Seconds of unchanged transcript (after some speech) before ending.
        public var silenceAfterSpeech: TimeInterval = 1.3
        /// Seconds with no transcript at all before giving up.
        public var noSpeechTimeout: TimeInterval = 6
        /// Shorter silence when the transcript already ends a sentence (. ? !). Nil or 0 turns it off.
        public var silenceAfterSentence: TimeInterval?
        /// The shorter silence needs at least this many words ("Play." alone is not a finished request).
        public var sentenceMinWords = 3
        /// Hard cap on one utterance.
        public var maxDuration: TimeInterval = 20
        public init() {}
    }

    public var settings: Settings
    public private(set) var startedAt: Date
    public private(set) var lastChangeAt: Date
    public private(set) var transcript: String = ""
    public private(set) var sawFinal = false

    public init(settings: Settings = Settings(), now: Date = Date()) {
        self.settings = settings
        startedAt = now
        lastChangeAt = now
    }

    /// Feed a transcript update. Returns true if the text changed.
    @discardableResult
    public mutating func update(_ u: TranscriptUpdate, at now: Date = Date()) -> Bool {
        if u.isFinal { sawFinal = true }
        let trimmed = u.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != transcript else { return false }
        transcript = trimmed
        lastChangeAt = now
        return true
    }

    /// Ask on a timer. Nil means keep listening.
    public func shouldEnd(at now: Date = Date()) -> Reason? {
        if sawFinal { return .finalResult }
        if now.timeIntervalSince(startedAt) >= settings.maxDuration { return .maxDuration }
        if transcript.isEmpty {
            return now.timeIntervalSince(startedAt) >= settings.noSpeechTimeout ? .noSpeech : nil
        }
        return now.timeIntervalSince(lastChangeAt) >= requiredSilence ? .silenceAfterSpeech : nil
    }

    /// How long the transcript must stay unchanged before the turn ends.
    public var requiredSilence: TimeInterval {
        guard let fast = settings.silenceAfterSentence, fast > 0, fast < settings.silenceAfterSpeech,
              let last = transcript.last, ".?!".contains(last),
              transcript.split(separator: " ").count >= settings.sentenceMinWords else { return settings.silenceAfterSpeech }
        return fast
    }
}
