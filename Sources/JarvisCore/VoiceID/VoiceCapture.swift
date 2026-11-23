import Foundation

/// Keeps the audio of the request being spoken, so the voice can be checked once the request is complete.
/// A short pre-roll is always held, so "Hey Jarvis" itself is part of the sample: more speech, better check.
/// Audio lives in RAM only and is dropped as soon as it has been checked.
public final class UtteranceRecorder: @unchecked Sendable {
    public var preRollSeconds: Double
    public var maxSeconds: Double
    private let sampleRate = 16_000
    private let lock = NSLock()
    private var preRoll: [Float] = []
    private var capture: [Float]?

    public init(preRollSeconds: Double = 2, maxSeconds: Double = 30) {
        self.preRollSeconds = preRollSeconds; self.maxSeconds = maxSeconds
    }

    /// Every microphone chunk goes through here. Capture queue.
    public func feed(_ chunk: [Float]) {
        lock.lock(); defer { lock.unlock() }
        if capture != nil {
            if capture!.count < Int(maxSeconds * Double(sampleRate)) { capture!.append(contentsOf: chunk) }
        } else {
            preRoll.append(contentsOf: chunk)
            let limit = Int(preRollSeconds * Double(sampleRate))
            if preRoll.count > limit { preRoll.removeFirst(preRoll.count - limit) }
        }
    }

    /// Start keeping audio. Without the pre-roll for follow-ups: what came just before is Jarvis's own voice.
    public func begin(includePreRoll: Bool) {
        lock.lock(); defer { lock.unlock() }
        capture = includePreRoll ? preRoll : []
        preRoll = []
    }

    /// Stop and hand over what was heard. Nothing is kept.
    public func end() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let out = capture ?? []
        capture = nil
        return out
    }

    public func discard() { lock.lock(); capture = nil; lock.unlock() }
}

/// What an approval may accept, given whose voice made the request.
public enum VoiceGate: Equatable, Sendable {
    /// Voice ID is off or the voice matched: "yes" by voice or the button.
    case voiceOrButton
    /// The voice was not verified: only the Approve button counts. The associated text is what Jarvis says.
    case buttonOnly(String)
    /// The voice was not verified and the policy forbids going further.
    case refuse(String)

    /// - check: the voice check of the request, nil for a typed request.
    /// - enrolled: whether Voice ID is set up.
    /// - policy: "button" (approve on screen instead) or "never" (refuse).
    public static func decide(check: VoiceCheck?, enrolled: Bool, policy: String) -> VoiceGate {
        guard enrolled else { return .voiceOrButton }
        guard let check else { return .buttonOnly("That was typed, so approve it on screen") }
        if check.isVerified { return .voiceOrButton }
        let why: String
        switch check.outcome {
        case .tooShort: why = "I didn't hear enough to be sure it's you"
        case .unavailable: why = "I can't check your voice right now"
        default: why = "I couldn't verify your voice"
        }
        return policy.lowercased() == "never" ? .refuse("\(why), so I won't do that.") : .buttonOnly("\(why), so approve it on screen")
    }

    public var acceptsSpokenYes: Bool { self == .voiceOrButton }
}

/// Cuts one spoken sentence out of the microphone stream for enrollment: waits for speech, then stops after
/// a pause. Pure logic over audio chunks, so it can be tested with recorded files.
public struct SentenceRecorder {
    public enum Status: Equatable { case waiting, recording, done, timedOut }
    public var speechLevel: Float = 0.012         // RMS that counts as speech
    public var endSilence: Double = 0.9
    public var minSpeech: Double = 1.5
    public var maxSeconds: Double = 12
    public private(set) var status: Status = .waiting
    public private(set) var samples: [Float] = []
    private var lead: [Float] = []                // a little audio from just before speech began
    private var speechSeconds = 0.0
    private var silenceSeconds = 0.0
    private var totalSeconds = 0.0

    public init() {}

    /// Seconds of actual speech heard.
    public var spoken: Double { speechSeconds }

    public mutating func feed(_ chunk: [Float]) {
        guard status == .waiting || status == .recording, !chunk.isEmpty else { return }
        let seconds = Double(chunk.count) / 16_000
        totalSeconds += seconds
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let loud = (sum / Float(chunk.count)).squareRoot() >= speechLevel
        if status == .waiting {
            if loud {
                status = .recording
                samples = lead + chunk
                speechSeconds = seconds
            } else {
                lead = Array((lead + chunk).suffix(3_200))        // keep the last 200 ms
            }
        } else {
            samples.append(contentsOf: chunk)
            if loud { speechSeconds += seconds; silenceSeconds = 0 } else { silenceSeconds += seconds }
            if silenceSeconds >= endSilence, speechSeconds >= minSpeech { status = .done }
        }
        if status != .done, totalSeconds >= maxSeconds { status = speechSeconds >= minSpeech ? .done : .timedOut }
    }
}
