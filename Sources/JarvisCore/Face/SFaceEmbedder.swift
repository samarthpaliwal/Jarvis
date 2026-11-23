import CoreGraphics
import Foundation
import OnnxRuntimeBindings

/// SFace (OpenCV model zoo, Apache 2.0) on ONNX Runtime: a face becomes 128 numbers, fully on-device.
/// Preprocessing follows OpenCV's own FaceRecognizerSF: a 112×112 aligned crop, RGB, values 0 to 255.
public final class SFaceEmbedder: FaceEmbedding, @unchecked Sendable {
    public static let fileName = "face_recognition_sface_2021dec.onnx"
    public static let sha256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
    public let modelName = "sface-2021dec"

    private let env: ORTEnv
    private let session: ORTSession
    private let inputName: String
    private let outputName: String
    private let lock = NSLock()

    public static var defaultURL: URL {
        ConfigLocator.userConfigDirectory.deletingLastPathComponent().appendingPathComponent("models/\(fileName)")
    }
    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: defaultURL.path) }

    public init(modelURL: URL = SFaceEmbedder.defaultURL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw FaceError.modelMissing(modelURL.path) }
        do {
            env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(2)
            try options.setGraphOptimizationLevel(.all)
            session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
            inputName = try session.inputNames().first ?? "data"
            outputName = try session.outputNames().first ?? "fc1"
        } catch { throw FaceError.modelFailed(error.localizedDescription) }
    }

    /// The aligned crop as the model wants it: three planes (R, G, B), each 112×112, values 0 to 255.
    public static func crop(_ image: CGImage, face: FaceObservation) -> [Float]? {
        guard let t = FaceAlign.transform(for: face) else { return nil }
        let side = FaceAlign.side
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.translateBy(x: 0, y: CGFloat(side)); ctx.scaleBy(x: 1, y: -1)        // crop: origin top-left
            ctx.concatenate(t)                                                       // picture → crop
            ctx.translateBy(x: 0, y: CGFloat(image.height)); ctx.scaleBy(x: 1, y: -1) // picture: origin top-left
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard ok else { return nil }
        let plane = side * side
        var out = [Float](repeating: 0, count: plane * 3)
        for i in 0..<plane {
            out[i] = Float(pixels[i * 4]); out[plane + i] = Float(pixels[i * 4 + 1]); out[2 * plane + i] = Float(pixels[i * 4 + 2])
        }
        return out
    }

    public func embed(_ image: CGImage, face: FaceObservation) throws -> [Float] {
        guard let input = Self.crop(image, face: face) else { throw FaceError.modelFailed("the face is too small to read") }
        return try embed(crop: input)
    }

    public func embed(crop input: [Float]) throws -> [Float] {
        lock.lock(); defer { lock.unlock() }
        do {
            let side = NSNumber(value: FaceAlign.side)
            let data = NSMutableData(bytes: input, length: input.count * MemoryLayout<Float>.size)
            let value = try ORTValue(tensorData: data, elementType: .float, shape: [1, 3, side, side])
            let outputs = try session.run(withInputs: [inputName: value], outputNames: [outputName], runOptions: nil)
            guard let out = outputs[outputName] else { throw FaceError.modelFailed("no output") }
            let bytes = try out.tensorData() as Data
            let raw = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard raw.count >= 64, raw.allSatisfy(\.isFinite) else { throw FaceError.modelFailed("unexpected output") }
            return FaceMath.normalized(raw)
        } catch let e as FaceError { throw e } catch { throw FaceError.modelFailed(error.localizedDescription) }
    }
}

/// Loads the model the first time a face needs measuring, then keeps it.
public final class LazySFaceEmbedder: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: SFaceEmbedder?
    public init() {}
    public func get() throws -> any FaceEmbedding {
        lock.lock(); defer { lock.unlock() }
        if let loaded { return loaded }
        let e = try SFaceEmbedder()
        loaded = e
        return e
    }
}
