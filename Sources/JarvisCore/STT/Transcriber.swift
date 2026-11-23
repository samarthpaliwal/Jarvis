import Foundation

public struct TranscriptUpdate: Equatable, Sendable {
    public var text: String
    public var isFinal: Bool
    public init(text: String, isFinal: Bool) { self.text = text; self.isFinal = isFinal }
}

/// Speech-to-text behind one small surface so Deepgram / whisper.cpp can replace Apple later.
/// Audio arrives as 16 kHz mono Float32 chunks from `AudioCapture`.
public protocol Transcriber: AnyObject {
    /// Human-readable engine name for logs and the menu.
    var name: String { get }
    /// True when the engine can run right now (permission granted, model available).
    var isAvailable: Bool { get }
    func requestAuthorization() async -> Bool
    /// Begin a new utterance. Updates and errors are delivered on the main queue.
    func start(onUpdate: @escaping (TranscriptUpdate) -> Void, onError: @escaping (Error) -> Void) throws
    /// Feed audio. May be called from any queue.
    func append(samples: [Float])
    /// No more audio; deliver the final result.
    func finish()
    /// Abort without a final result.
    func cancel()
    /// After `start`, waits until audio can be appended without any of it being dropped. Live microphone
    /// audio does not need this; a whole recording fed at once does. False when it did not get ready in time.
    func waitUntilAcceptingAudio(timeout: TimeInterval) async -> Bool
}

public extension Transcriber {
    func waitUntilAcceptingAudio(timeout: TimeInterval) async -> Bool { true }
    /// True when this engine would send audio off this Mac. On-device engines keep the default.
    var sendsAudioOffDevice: Bool { false }
}

/// Transcribes one finished recording (a remote request) with a streaming transcriber.
public enum UtteranceTranscription {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Error>?
        private var partial = ""
        func set(_ c: CheckedContinuation<String, Error>) { lock.lock(); continuation = c; lock.unlock() }
        func note(_ text: String) { lock.lock(); partial = text; lock.unlock() }
        var last: String { lock.lock(); defer { lock.unlock() }; return partial }
        func resume(_ result: Result<String, Error>) {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.resume(with: result)
        }
    }

    /// - samples: 16 kHz mono. Returns what was said, or "" when there was no speech.
    public static func transcribe(_ samples: [Float], with transcriber: Transcriber, timeout: TimeInterval = 30) async throws -> String {
        guard await transcriber.requestAuthorization() else { throw TranscriberError.notAuthorized }
        nonisolated(unsafe) let t = transcriber
        let box = Box()
        defer { t.cancel() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            box.set(cont)
            do {
                try t.start(onUpdate: { update in
                    box.note(update.text)
                    if update.isFinal { box.resume(.success(update.text)) }
                }, onError: { error in
                    // Recognizers report "no speech" as an error. With nothing heard, that is an empty result.
                    box.last.isEmpty ? box.resume(.success("")) : box.resume(.success(box.last))
                    _ = error
                })
            } catch {
                box.resume(.failure(error))
                return
            }
            Task {
                _ = await t.waitUntilAcceptingAudio(timeout: 5)
                let chunk = 1280     // 80 ms, the size the microphone delivers
                var i = 0
                while i < samples.count {
                    t.append(samples: Array(samples[i..<min(i + chunk, samples.count)]))
                    i += chunk
                }
                // A little silence lets the recognizer close the last word.
                t.append(samples: [Float](repeating: 0, count: 8000))
                t.finish()
                try? await Task.sleep(for: .seconds(timeout))
                box.resume(.success(box.last))
            }
        }
    }
}

public enum TranscriberError: LocalizedError {
    case notAuthorized
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition permission was not granted."
        case .unavailable(let why): return "Speech recognition unavailable: \(why)"
        }
    }
}
