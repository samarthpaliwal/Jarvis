import Foundation
import OnnxRuntimeBindings

/// openWakeWord "hey jarvis" running on ONNX Runtime, fully on-device.
///
/// Pipeline per 80 ms chunk (mirrors openWakeWord's streaming path):
///   audio (1280 + 480 context samples) → melspectrogram.onnx → mel frames (32 bins), x/10 + 2
///   last 76 mel frames → embedding_model.onnx → 96-d feature
///   last 16 features → hey_jarvis_v0.1.onnx → score
public final class OpenWakeWordDetector: WakeWordDetector {
    public var threshold: Float = 0.5
    /// Milliseconds spent in the three ONNX sessions for the most recent chunk.
    public private(set) var lastInferenceMillis: Double = 0

    private let env: ORTEnv
    private let mel: Model
    private let embedding: Model
    private let wake: Model

    private var raw: [Float] = []           // trailing audio, ≤ 1 s
    private var melFrames: [Float] = []     // flattened frames × 32
    private var features: [Float] = []      // flattened embeddings × 96

    private static let melBins = 32
    private static let melWindow = 76
    private static let featureDim = 96
    private static let featureWindow = 16
    private static let contextSamples = 480 // 3 extra mel frames of context, like openWakeWord

    private struct Model {
        let session: ORTSession
        let inputName: String
        let outputName: String

        init(env: ORTEnv, url: URL) throws {
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(1)
            try options.setGraphOptimizationLevel(.all)
            session = try ORTSession(env: env, modelPath: url.path, sessionOptions: options)
            inputName = try session.inputNames().first ?? "input"
            outputName = try session.outputNames().first ?? "output"
        }

        func run(_ values: [Float], shape: [Int]) throws -> [Float] {
            let data = NSMutableData(bytes: values, length: values.count * MemoryLayout<Float>.size)
            let input = try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
            let outputs = try session.run(withInputs: [inputName: input], outputNames: [outputName], runOptions: nil)
            guard let out = outputs[outputName] else { return [] }
            let bytes = try out.tensorData() as Data
            return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
    }

    public init(modelDirectory: URL) throws {
        env = try ORTEnv(loggingLevel: .warning)
        mel = try Model(env: env, url: modelDirectory.appendingPathComponent("melspectrogram.onnx"))
        embedding = try Model(env: env, url: modelDirectory.appendingPathComponent("embedding_model.onnx"))
        wake = try Model(env: env, url: modelDirectory.appendingPathComponent("hey_jarvis_v0.1.onnx"))
        JarvisLog.info("openWakeWord loaded from \(modelDirectory.lastPathComponent) (mel:\(mel.inputName) emb:\(embedding.inputName) wake:\(wake.inputName))")
    }

    /// Loads the models shipped inside the app bundle.
    public static func bundled() throws -> OpenWakeWordDetector {
        guard let dir = Bundle.module.url(forResource: "Models", withExtension: nil) else {
            throw NSError(domain: "Jarvis.Wake", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bundled wake word models not found"])
        }
        return try OpenWakeWordDetector(modelDirectory: dir)
    }

    public func reset() {
        pendingChunks = 0
        lastScore = 0
        raw.removeAll(keepingCapacity: true)
        melFrames.removeAll(keepingCapacity: true)
        features.removeAll(keepingCapacity: true)
    }

    /// Chunks accumulated before one inference pass. Higher = fewer wakeups = lower idle CPU,
    /// at the cost of up to (batchSize − 1) × 80 ms extra detection latency.
    public var batchSize: Int = 2
    private var pendingChunks = 0
    private var lastScore: Float = 0

    public func process(chunk: [Float]) throws -> Float {
        raw.append(contentsOf: chunk)
        if raw.count > 32_000 { raw.removeFirst(raw.count - 32_000) }
        pendingChunks += 1
        guard pendingChunks >= max(1, batchSize) else { return lastScore }
        let n = pendingChunks
        pendingChunks = 0

        let start = DispatchTime.now()
        defer { lastInferenceMillis = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6 }

        // 1. Mel spectrogram over the new audio plus a little context.
        let window = Array(raw.suffix(min(raw.count, n * AudioCapture.chunkSize + Self.contextSamples)))
        let melOut = try mel.run(window, shape: [1, window.count]).map { $0 / 10 + 2 }
        let newFrames = melOut.count / Self.melBins
        melFrames.append(contentsOf: melOut)
        let maxMel = (Self.melWindow + 8 * 16) * Self.melBins
        if melFrames.count > maxMel { melFrames.removeFirst(melFrames.count - maxMel) }
        let totalFrames = melFrames.count / Self.melBins
        guard totalFrames >= Self.melWindow, newFrames > 0 else { return 0 }

        // 2. One embedding per chunk, batched: windows of 76 frames ending every `step` frames.
        let step = max(1, newFrames / n)
        var batch: [Float] = []
        var count = 0
        for i in stride(from: n - 1, through: 0, by: -1) {
            let end = totalFrames - step * i
            guard end >= Self.melWindow else { continue }
            batch.append(contentsOf: melFrames[(end - Self.melWindow) * Self.melBins ..< end * Self.melBins])
            count += 1
        }
        guard count > 0 else { return 0 }
        let emb = try embedding.run(batch, shape: [count, Self.melWindow, Self.melBins, 1])
        guard emb.count == count * Self.featureDim else { return 0 }

        // 3. Score the wake classifier after each new embedding; report the best.
        var best: Float = 0
        let maxFeat = Self.featureWindow * Self.featureDim
        for k in 0..<count {
            features.append(contentsOf: emb[k * Self.featureDim ..< (k + 1) * Self.featureDim])
            if features.count > maxFeat { features.removeFirst(features.count - maxFeat) }
            if features.count == maxFeat {
                best = max(best, try wake.run(features, shape: [1, Self.featureWindow, Self.featureDim]).first ?? 0)
            }
        }
        lastScore = best
        return best
    }
}
