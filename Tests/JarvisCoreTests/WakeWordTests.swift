import XCTest
import AVFoundation
@testable import JarvisCore

/// Runs the real openWakeWord models. Uses the macOS `say` voice to synthesize test phrases.
final class WakeWordTests: XCTestCase {
    func testSilenceDoesNotTrigger() throws {
        let detector = try OpenWakeWordDetector.bundled()
        var peak: Float = 0
        for _ in 0..<60 { // ~5 s of silence
            peak = max(peak, try detector.process(chunk: Array(repeating: 0, count: AudioCapture.chunkSize)))
        }
        XCTAssertLessThan(peak, 0.2)
        XCTAssertLessThan(detector.lastInferenceMillis, 40, "inference should be cheap")
    }

    func testSynthesizedHeyJarvisTriggers() throws {
        guard let samples = Self.synthesize("hey jarvis") else {
            throw XCTSkip("`say` is unavailable in this environment")
        }
        for batch in [1, 2, 4] {
            let detector = try OpenWakeWordDetector.bundled()
            detector.batchSize = batch
            let peak = try Self.peakScore(detector, samples)
            print("WAKE batch=\(batch) hey jarvis peak=\(peak)")
            XCTAssertGreaterThanOrEqual(peak, 0.5, "batch \(batch): synthesized 'hey jarvis' should score ≥ 0.5 (got \(peak))")
        }
    }

    func testSynthesizedOtherPhraseDoesNotTrigger() throws {
        guard let samples = Self.synthesize("good morning, what is the weather like today") else {
            throw XCTSkip("`say` is unavailable in this environment")
        }
        for batch in [1, 2, 4] {
            let detector = try OpenWakeWordDetector.bundled()
            detector.batchSize = batch
            let peak = try Self.peakScore(detector, samples)
            print("WAKE batch=\(batch) other phrase peak=\(peak)")
            XCTAssertLessThan(peak, 0.5, "batch \(batch): unrelated speech should stay under threshold (got \(peak))")
        }
    }

    // MARK: helpers

    static func peakScore(_ detector: OpenWakeWordDetector, _ samples: [Float]) throws -> Float {
        var peak: Float = 0
        // Lead-in and tail of silence so the streaming buffers settle, like real use.
        let padded = Array(repeating: Float(0), count: 16_000) + samples + Array(repeating: Float(0), count: 16_000)
        var i = 0
        while i + AudioCapture.chunkSize <= padded.count {
            peak = max(peak, try detector.process(chunk: Array(padded[i..<i + AudioCapture.chunkSize])))
            i += AudioCapture.chunkSize
        }
        return peak
    }

    /// Returns 16 kHz mono Float32 samples of `text` spoken by the system voice, or nil.
    static func synthesize(_ text: String) -> [Float]? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-tts-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        proc.arguments = ["-o", url.path, "--data-format=LEI16@16000", "--file-format=WAVE", text]
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let file = try? AVAudioFile(forReading: url),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}

import JarvisObjC

final class AudioRecoveryTests: XCTestCase {
    /// The 2026-11-22 crash: AVAudioEngine raised NSException from installTap and the app aborted.
    func testObjCExceptionBecomesSwiftError() {
        XCTAssertThrowsError(try ObjCException.catching {
            NSException(name: .internalInconsistencyException, reason: "required condition is false: format.sampleRate == hwFormat.sampleRate").raise()
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("required condition is false"))
        }
        XCTAssertNoThrow(try ObjCException.catching { _ = 1 + 1 })
    }

    func testBackoffDoublesAndCaps() {
        XCTAssertEqual(AudioCapture.backoff(base: 1, attempt: 0, cap: 60), 1)
        XCTAssertEqual(AudioCapture.backoff(base: 1, attempt: 3, cap: 60), 8)
        XCTAssertEqual(AudioCapture.backoff(base: 6, attempt: 2, cap: 60), 24)
        XCTAssertEqual(AudioCapture.backoff(base: 6, attempt: 10, cap: 60), 60)
        XCTAssertEqual(AudioCapture.backoff(base: 6, attempt: 10_000, cap: 60), 60, "huge attempt counts must not overflow")
    }
}
