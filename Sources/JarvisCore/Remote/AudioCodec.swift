import AVFoundation
import Foundation

/// Audio in and out of the remote API: whatever the phone recorded becomes the 16 kHz mono samples the
/// rest of the pipeline uses, and a reply becomes a WAV the phone can play.
public enum AudioCodec {
    public enum CodecError: LocalizedError, Equatable {
        case empty
        case unsupported(String)
        case tooLong(seconds: Double, limit: Double)
        case unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .empty: return "There was no audio in the request."
            case .unsupported(let what): return "I can't read \(what) audio. Send WAV or M4A."
            case .tooLong(let s, let limit): return "That recording is \(Int(s)) seconds long; the limit is \(Int(limit))."
            case .unreadable(let why): return "I couldn't read that audio: \(why)"
            }
        }
    }

    public static let sampleRate = 16_000.0

    /// The file type, judged by the first bytes rather than by what the client claims.
    static func kind(of data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data.prefix(12))
        func tag(_ i: Int) -> String { String(bytes: b[i..<i + 4], encoding: .ascii) ?? "" }
        if tag(0) == "RIFF", tag(8) == "WAVE" { return "wav" }
        if tag(4) == "ftyp" { return "m4a" }
        if tag(0) == "caff" { return "caf" }
        if tag(0) == "FORM" { return "aiff" }
        if tag(0).hasPrefix("ID3") || (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) { return "mp3" }
        if tag(0) == "OggS" { return "ogg" }
        if b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 { return "webm" }
        return nil
    }

    /// Decodes a recording to 16 kHz mono samples in -1…1.
    public static func decode(_ data: Data, maxSeconds: Double) throws -> [Float] {
        guard !data.isEmpty else { throw CodecError.empty }
        guard let kind = kind(of: data) else { throw CodecError.unsupported("that kind of") }
        guard ["wav", "m4a", "caf", "aiff", "mp3"].contains(kind) else { throw CodecError.unsupported(kind.uppercased()) }
        // AVAudioFile reads from disk. The copy lives for the length of this call, in a private directory.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("in.\(kind)")
        try data.write(to: url, options: .atomic)
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw CodecError.unreadable(error.localizedDescription) }
        let source = file.processingFormat
        let seconds = Double(file.length) / source.sampleRate
        guard file.length > 0 else { throw CodecError.empty }
        guard seconds <= maxSeconds else { throw CodecError.tooLong(seconds: seconds, limit: maxSeconds) }
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else { throw CodecError.unreadable("out of memory") }
        do { try file.read(into: input) } catch { throw CodecError.unreadable(error.localizedDescription) }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: source, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(seconds * sampleRate) + 4096) else {
            throw CodecError.unreadable("cannot convert \(Int(source.sampleRate)) Hz audio")
        }
        var served = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if served { status.pointee = .endOfStream; return nil }
            served = true
            status.pointee = .haveData
            return input
        }
        if let error { throw CodecError.unreadable(error.localizedDescription) }
        guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { throw CodecError.empty }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// 16-bit mono WAV.
    public static func wav(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); le(36 + bytes); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le(UInt32(16)); le(UInt16(1)); le(UInt16(1))
        le(UInt32(sampleRate)); le(UInt32(sampleRate * 2)); le(UInt16(2)); le(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); le(bytes)
        for s in samples { le(Int16((max(-1, min(1, s)) * 32767).rounded())) }
        return data
    }
}
