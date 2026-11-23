import Foundation

/// What enrollment needs from the app: a way to speak, to show text, to hear, and to keep everything else
/// quiet meanwhile. `ConversationController` provides it; tests provide a fake.
@MainActor
public protocol EnrollmentHost: AnyObject {
    /// Stops wake-word handling and normal listening for the duration. Returns false if Jarvis is busy.
    func beginEnrollment() -> Bool
    func endEnrollment()
    /// Speaks and returns when the audio has finished and the room has had a moment to go quiet.
    func say(_ text: String) async
    /// Shows a step on screen without speaking.
    func show(title: String, text: String)
    /// A short tone: "your turn".
    func tone() async
    /// Delivers microphone chunks (16 kHz mono) until the returned closure is called.
    func listen(_ onChunk: @escaping @Sendable ([Float]) -> Void) -> () -> Void
}

/// The guided enrollment: Jarvis asks for five sentences, records each one, and builds the voiceprint.
/// Only the voiceprint is kept. The recordings are discarded when this finishes, whatever the outcome.
@MainActor
public final class VoiceEnrollment {
    public static let sentences = [
        "Hey Jarvis, what's on my calendar tomorrow?",
        "Hey Jarvis, send an email to my lab partner about Friday.",
        "Move my study session to three in the afternoon.",
        "Hey Jarvis, play some music while I get ready for class.",
        "Remind me to call home on Sunday evening.",
    ]

    public enum Outcome: Equatable {
        case enrolled(samples: Int, consistency: Double)
        case busy
        case failed(String)
    }

    private let verifier: SpeakerVerifier
    private weak var host: (any EnrollmentHost)?
    public var sentences = VoiceEnrollment.sentences
    public var retriesPerSentence = 2
    /// How often the recorder is polled while waiting for a sentence.
    public var pollMilliseconds = 100

    public init(verifier: SpeakerVerifier, host: any EnrollmentHost) {
        self.verifier = verifier; self.host = host
    }

    /// One sentence from the microphone, or nil if nothing usable was said.
    private func record() async -> [Float]? {
        guard let host else { return nil }
        let box = RecorderBox()
        let stop = host.listen { chunk in box.feed(chunk) }
        defer { stop() }
        while true {
            try? await Task.sleep(for: .milliseconds(pollMilliseconds))
            switch box.status {
            case .done: return box.samples
            case .timedOut: return nil
            default: if Task.isCancelled { return nil }
            }
        }
    }

    public func run() async -> Outcome {
        guard let host else { return .failed("not available") }
        guard host.beginEnrollment() else { return .busy }
        defer { host.endEnrollment() }

        await host.say("Let's set up Voice ID. I'll show \(sentences.count) sentences. After each tone, read the one on screen in your normal voice.")
        var recordings: [[Float]] = []
        for (i, sentence) in sentences.enumerated() {
            var got: [Float]?
            for attempt in 0...retriesPerSentence {
                host.show(title: "Voice ID \(i + 1) of \(sentences.count)", text: sentence)
                await host.tone()
                got = await record()
                if got != nil { break }
                if attempt < retriesPerSentence { await host.say("I didn't catch that. Once more after the tone.") }
            }
            guard let sample = got else {
                await host.say("I couldn't hear that one, so I've stopped. Nothing was saved. Try again somewhere quieter.")
                return .failed("no speech for sentence \(i + 1)")
            }
            recordings.append(sample)
        }
        host.show(title: "Voice ID", text: "Working it out…")
        let verifier = verifier
        let result: Result<Voiceprint, Error> = await Task.detached { Result { try verifier.enroll(recordings) } }.value
        recordings.removeAll()                                   // the audio is not needed any more
        switch result {
        case .success(let print):
            JarvisLog.info(String(format: "Voice ID: enrolled from %d recordings, consistency %.2f (lowest %.2f)", print.samples, print.selfScoreMean, print.selfScoreMin))
            host.show(title: "Voice ID is on", text: "\(print.samples) recordings. The voiceprint stays on this Mac.")
            await host.say("Voice ID is set up. From now on I'll check it's you before anything that needs your approval.")
            return .enrolled(samples: print.samples, consistency: print.selfScoreMean)
        case .failure(let error):
            JarvisLog.warn("Voice ID: enrollment failed: \(error.localizedDescription)")
            await host.say("\(error.localizedDescription) Nothing was saved.")
            return .failed(error.localizedDescription)
        }
    }
}

/// Thread-safe wrapper so the capture queue can feed the recorder while the main actor polls it.
final class RecorderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder = SentenceRecorder()
    func feed(_ chunk: [Float]) { lock.lock(); recorder.feed(chunk); lock.unlock() }
    var status: SentenceRecorder.Status { lock.lock(); defer { lock.unlock() }; return recorder.status }
    var samples: [Float] { lock.lock(); defer { lock.unlock() }; return recorder.samples }
}
