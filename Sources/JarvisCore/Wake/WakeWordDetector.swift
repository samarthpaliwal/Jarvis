import Foundation

/// Anything that can score 80 ms chunks of 16 kHz audio for the wake phrase.
/// `OpenWakeWordDetector` is the default; a Porcupine-backed one would conform the same way.
public protocol WakeWordDetector: AnyObject {
    /// Score at or above this fires a detection. 0...1.
    var threshold: Float { get set }
    /// Feed exactly `AudioCapture.chunkSize` samples. Returns the current wake score 0...1.
    func process(chunk: [Float]) throws -> Float
    /// Forget all audio context (call after a detection or when capture restarts).
    func reset()
}
