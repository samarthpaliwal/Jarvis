import Foundation
import OnnxRuntimeBindings

public enum VoiceIDError: LocalizedError, Equatable {
    case modelMissing(String)
    case tooShort(Double)
    case notEnrolled
    case inconsistent(Double)
    case notEnoughSamples(Int)
    case modelFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let path): return "The voice model is not installed. Run scripts/setup-voiceid.sh (expected at \(path))."
        case .tooShort(let s): return String(format: "I need a bit more speech than that (%.1f seconds heard).", s)
        case .notEnrolled: return "Voice ID is not set up yet."
        case .inconsistent(let score): return String(format: "Those recordings don't sound like the same voice to me (%.2f). Try again somewhere quieter.", score)
        case .notEnoughSamples(let n): return "I only got \(n) usable recordings. I need at least three."
        case .modelFailed(let why): return "The voice model failed: \(why)"
        }
    }
}

/// Turns a stretch of speech into a voice embedding: a list of numbers that is similar for the same voice
/// and different for other voices. Behind an interface so tests can run without the model file.
public protocol SpeakerEmbedding: AnyObject, Sendable {
    var modelName: String { get }
    /// A unit-length embedding for 16 kHz mono samples in −1…1.
    func embed(_ samples: [Float]) throws -> [Float]
}

public enum VoiceMath {
    public static func normalized(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? Double(dot / (sqrt(na) * sqrt(nb))) : 0
    }

    public static func centroid(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == first.count { for i in v.indices { sum[i] += v[i] } }
        return normalized(sum)
    }

    /// Cuts silence off both ends, so a pause before or after speaking does not dilute the voice.
    public static func trimSilence(_ samples: [Float], sampleRate: Int = 16_000) -> [Float] {
        let hop = sampleRate / 50                      // 20 ms
        guard samples.count >= hop * 5 else { return samples }
        var levels: [Float] = []
        var i = 0
        while i + hop <= samples.count {
            var sum: Float = 0
            for j in i..<(i + hop) { sum += samples[j] * samples[j] }
            levels.append((sum / Float(hop)).squareRoot())
            i += hop
        }
        let loud = levels.sorted()[Int(Double(levels.count) * 0.95)]
        let threshold = max(0.004, loud * 0.1)
        guard let first = levels.firstIndex(where: { $0 > threshold }), let last = levels.lastIndex(where: { $0 > threshold }) else { return [] }
        let start = max(0, (first - 5) * hop), end = min(samples.count, (last + 6) * hop)      // keep 100 ms of margin
        return Array(samples[start..<end])
    }
}

/// ECAPA-TDNN (WeSpeaker, VoxCeleb, CC-BY-4.0) on ONNX Runtime: 192-number embeddings, fully on-device.
public final class ECAPAEmbedder: SpeakerEmbedding, @unchecked Sendable {
    public static let fileName = "voxceleb_ECAPA512_LM.onnx"
    public static let sha256 = "d71b85d9b48058ef68004f04f1b78acebefb9dfcf542e19b976a12a5ad1f10b0"
    public let modelName = "wespeaker-ecapa-tdnn512-lm"
    /// Less speech than this gives an unreliable embedding.
    public static let minimumSeconds = 0.6

    private let env: ORTEnv
    private let session: ORTSession
    private let inputName: String
    private let outputName: String
    private let lock = NSLock()

    public static var defaultURL: URL {
        ConfigLocator.userConfigDirectory.deletingLastPathComponent().appendingPathComponent("models/\(fileName)")
    }

    public init(modelURL: URL = ECAPAEmbedder.defaultURL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw VoiceIDError.modelMissing(modelURL.path) }
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(.all)
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        inputName = try session.inputNames().first ?? "feats"
        outputName = try session.outputNames().first ?? "embs"
    }

    public func embed(_ samples: [Float]) throws -> [Float] {
        let seconds = Double(samples.count) / Fbank.sampleRate
        guard seconds >= Self.minimumSeconds else { throw VoiceIDError.tooShort(seconds) }
        let (frames, features) = Fbank.compute(samples)
        guard frames > 0 else { throw VoiceIDError.tooShort(seconds) }
        lock.lock(); defer { lock.unlock() }
        do {
            let data = NSMutableData(bytes: features, length: features.count * MemoryLayout<Float>.size)
            let input = try ORTValue(tensorData: data, elementType: .float, shape: [1, NSNumber(value: frames), NSNumber(value: Fbank.melBins)])
            let outputs = try session.run(withInputs: [inputName: input], outputNames: [outputName], runOptions: nil)
            guard let out = outputs[outputName] else { throw VoiceIDError.modelFailed("no output") }
            let bytes = try out.tensorData() as Data
            let raw = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return VoiceMath.normalized(raw)
        } catch let e as VoiceIDError { throw e } catch { throw VoiceIDError.modelFailed(error.localizedDescription) }
    }
}

/// The enrolled voice. This is biometric data: it stays in one file on this Mac and is never logged or sent.
public struct Voiceprint: Codable, Equatable, Sendable {
    public var version = 1
    public var model: String
    public var embedding: [Float]
    public var samples: Int
    public var createdAt: Date
    /// How alike the enrollment recordings were to the final voiceprint (lowest and average).
    public var selfScoreMin: Double
    public var selfScoreMean: Double
}

/// Reads and writes the voiceprint: `~/Library/Application Support/Jarvis/voiceprint/voiceprint.json`,
/// readable only by this user (folder 0700, file 0600). Nothing else is ever stored: no audio.
public final class VoiceprintStore: @unchecked Sendable {
    public let url: URL
    public init(url: URL = VoiceprintStore.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        ConfigLocator.userConfigDirectory.deletingLastPathComponent().appendingPathComponent("voiceprint/voiceprint.json")
    }

    public func load() -> Voiceprint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(Voiceprint.self, from: data)
    }

    public func save(_ print: Voiceprint) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try e.encode(print).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func delete() { try? FileManager.default.removeItem(at: url) }
    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// The result of checking one utterance against the enrolled voice.
public struct VoiceCheck: Equatable, Sendable {
    public enum Outcome: String, Sendable {
        case verified           // sounds like the enrolled voice
        case mismatch           // sounds like someone else
        case tooShort           // not enough speech to tell
        case notEnrolled        // Voice ID is not set up: nothing to compare against
        case unavailable        // the model could not run
    }
    public var outcome: Outcome
    public var score: Double?
    public var seconds: Double

    public var isVerified: Bool { outcome == .verified }
    /// True when Voice ID is set up, so an unverified voice matters.
    public var isEnforced: Bool { outcome != .notEnrolled }
}

/// Enrollment and verification. All work is local.
public final class SpeakerVerifier: @unchecked Sendable {
    public let embedder: any SpeakerEmbedding
    public let store: VoiceprintStore
    /// Similarity needed to count as the enrolled voice (0…1).
    public var threshold: Double
    /// Enrollment recordings shorter than this are not used.
    public var minimumEnrollmentSeconds: Double = 1.5
    private let lock = NSLock()
    private var cached: Voiceprint?
    private var loaded = false

    public init(embedder: any SpeakerEmbedding, store: VoiceprintStore = VoiceprintStore(), threshold: Double = 0.5) {
        self.embedder = embedder; self.store = store; self.threshold = threshold
    }

    public var voiceprint: Voiceprint? {
        lock.lock(); defer { lock.unlock() }
        if !loaded { cached = store.load(); loaded = true }
        // A voiceprint made by a different model cannot be compared.
        return cached?.model == embedder.modelName ? cached : nil
    }

    public var isEnrolled: Bool { voiceprint != nil }

    /// Builds a voiceprint from several recordings of the same person and saves it.
    @discardableResult
    public func enroll(_ recordings: [[Float]], now: Date = Date()) throws -> Voiceprint {
        var embeddings: [[Float]] = []
        for r in recordings {
            let speech = VoiceMath.trimSilence(r)
            guard Double(speech.count) / Fbank.sampleRate >= minimumEnrollmentSeconds, let e = try? embedder.embed(speech) else { continue }
            embeddings.append(e)
        }
        guard embeddings.count >= 3 else { throw VoiceIDError.notEnoughSamples(embeddings.count) }
        // Every recording must sound like the others. Comparing each one with the average is too forgiving:
        // three different people each score about 0.6 against their own average. So compare them pairwise,
        // and drop a recording that does not match the rest (a cough, someone else talking).
        func agreement(_ i: Int, among list: [[Float]]) -> Double {
            let others = list.indices.filter { $0 != i }
            return others.map { VoiceMath.cosine(list[i], list[$0]) }.reduce(0, +) / Double(max(1, others.count))
        }
        let agreements = embeddings.indices.map { agreement($0, among: embeddings) }
        // Judge each recording against the ones that agree best, so one outlier cannot drag the rest down.
        let median = agreements.sorted()[agreements.count / 2]
        var kept = embeddings.indices.filter { agreements[$0] >= min(0.45, median - 0.15) }.map { embeddings[$0] }
        kept = kept.indices.filter { agreement($0, among: kept) >= 0.45 }.map { kept[$0] }
        guard kept.count >= 3 else { throw VoiceIDError.inconsistent(agreements.max() ?? 0) }
        let center = VoiceMath.centroid(kept)
        let scores = kept.map { VoiceMath.cosine($0, center) }
        let print = Voiceprint(model: embedder.modelName, embedding: center, samples: kept.count, createdAt: now,
                               selfScoreMin: scores.min() ?? 0, selfScoreMean: scores.reduce(0, +) / Double(scores.count))
        try store.save(print)
        lock.lock(); cached = print; loaded = true; lock.unlock()
        return print
    }

    public func forget() {
        store.delete()
        lock.lock(); cached = nil; loaded = true; lock.unlock()
    }

    /// Does this utterance sound like the enrolled voice?
    public func verify(_ samples: [Float]) -> VoiceCheck {
        let speech = VoiceMath.trimSilence(samples)
        let seconds = Double(speech.count) / Fbank.sampleRate
        guard let print = voiceprint else { return VoiceCheck(outcome: .notEnrolled, score: nil, seconds: seconds) }
        do {
            let e = try embedder.embed(speech)
            let score = VoiceMath.cosine(e, print.embedding)
            return VoiceCheck(outcome: score >= threshold ? .verified : .mismatch, score: score, seconds: seconds)
        } catch VoiceIDError.tooShort {
            return VoiceCheck(outcome: .tooShort, score: nil, seconds: seconds)
        } catch {
            JarvisLog.warn("Voice ID: could not check the voice: \(error.localizedDescription)")
            return VoiceCheck(outcome: .unavailable, score: nil, seconds: seconds)
        }
    }
}

/// Loads the real model the first time it is needed. Until Voice ID is set up, the 25 MB model stays on disk.
public final class LazyECAPAEmbedder: SpeakerEmbedding, @unchecked Sendable {
    public let modelName = "wespeaker-ecapa-tdnn512-lm"
    private let url: URL
    private let lock = NSLock()
    private var loaded: ECAPAEmbedder?

    public init(modelURL: URL = ECAPAEmbedder.defaultURL) { url = modelURL }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func embed(_ samples: [Float]) throws -> [Float] {
        lock.lock()
        if loaded == nil {
            do { loaded = try ECAPAEmbedder(modelURL: url); JarvisLog.info("Voice ID: model loaded") }
            catch { lock.unlock(); throw error }
        }
        let model = loaded!
        lock.unlock()
        return try model.embed(samples)
    }
}
