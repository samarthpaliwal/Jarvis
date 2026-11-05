import XCTest
import OnnxRuntimeBindings
@testable import JarvisCore

/// Prints per-model inference cost. Not an assertion test; run with `swift test --filter Benchmark`.
final class WakeWordBenchmark: XCTestCase {
    func testPerModelTiming() throws {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "Models", withExtension: nil))
        let env = try ORTEnv(loggingLevel: .warning)

        func session(_ name: String, coreML: Bool) throws -> ORTSession {
            let o = try ORTSessionOptions()
            try o.setIntraOpNumThreads(1)
            try o.setGraphOptimizationLevel(.all)
            if coreML {
                let c = ORTCoreMLExecutionProviderOptions()
                c.enableOnSubgraphs = true
                try o.appendCoreMLExecutionProvider(with: c)
            }
            return try ORTSession(env: env, modelPath: dir.appendingPathComponent(name).path, sessionOptions: o)
        }
        func run(_ s: ORTSession, _ shape: [Int], iterations: Int = 200) throws -> Double {
            let n = shape.reduce(1, *)
            let data = NSMutableData(bytes: [Float](repeating: 0.01, count: n), length: n * 4)
            let input = try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
            let inName = try s.inputNames().first!, outName = try s.outputNames().first!
            _ = try s.run(withInputs: [inName: input], outputNames: [outName], runOptions: nil)
            let t0 = DispatchTime.now()
            for _ in 0..<iterations { _ = try s.run(withInputs: [inName: input], outputNames: [outName], runOptions: nil) }
            return Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6 / Double(iterations)
        }

        // Per-model Core ML feasibility
        for name in ["melspectrogram.onnx", "embedding_model.onnx", "hey_jarvis_v0.1.onnx"] {
            do {
                let s = try session(name, coreML: true)
                let shape = name.hasPrefix("mel") ? [1, 1760] : name.hasPrefix("emb") ? [1, 76, 32, 1] : [1, 16, 96]
                print(String(format: "BENCH coreML %@ = %.3f ms", name, try run(s, shape)))
            } catch { print("BENCH coreML \(name) failed: \(error.localizedDescription.prefix(80))") }
        }
        // QoS effect: same CPU pipeline on a utility vs userInitiated queue
        for qos in [DispatchQoS.utility, .userInitiated] {
            let emb = try session("embedding_model.onnx", coreML: false)
            let q = DispatchQueue(label: "bench", qos: qos)
            let exp = expectation(description: "bench")
            q.async {
                let ms = try! run(emb, [1, 76, 32, 1], iterations: 300)
                print(String(format: "BENCH qos=%@ emb=%.3f ms", qos == .utility ? "utility" : "userInitiated", ms))
                exp.fulfill()
            }
            wait(for: [exp], timeout: 60)
        }
        for coreML in [false] {
            do {
                let mel = try session("melspectrogram.onnx", coreML: coreML)
                let emb = try session("embedding_model.onnx", coreML: coreML)
                let wake = try session("hey_jarvis_v0.1.onnx", coreML: coreML)
                let m1 = try run(mel, [1, 1760]), m2 = try run(mel, [1, 3040])
                let e1 = try run(emb, [1, 76, 32, 1]), e2 = try run(emb, [2, 76, 32, 1])
                let w = try run(wake, [1, 16, 96])
                print(String(format: "BENCH coreML=%d  mel(1760)=%.3f ms  mel(3040)=%.3f ms  emb(1)=%.3f ms  emb(2)=%.3f ms  wake=%.3f ms  | per-80ms: single=%.3f  batched2=%.3f",
                             coreML ? 1 : 0, m1, m2, e1, e2, w, m1 + e1 + w, (m2 + e2 + w) / 2))
            } catch {
                print("BENCH coreML=\(coreML) failed: \(error)")
            }
        }
    }
}
