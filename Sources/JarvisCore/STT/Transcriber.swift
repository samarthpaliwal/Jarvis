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
