import AVFoundation
import CoreImage
import Foundation

/// One still image for the model to look at.
public struct Frame: Sendable {
    /// JPEG bytes, already scaled down.
    public var jpeg: Data
    public var width: Int
    public var height: Int
    /// Where it came from: "camera", "glasses".
    public var source: String
    public var capturedAt: Date
    public init(jpeg: Data, width: Int, height: Int, source: String, capturedAt: Date = Date()) {
        self.jpeg = jpeg; self.width = width; self.height = height; self.source = source; self.capturedAt = capturedAt
    }
}

public enum VisionError: LocalizedError, Equatable {
    case cameraDenied
    case noCamera
    case timedOut
    case noFrame(String)
    case unknownSource(String)

    public var errorDescription: String? {
        switch self {
        case .cameraDenied: return "I don't have camera access. Turn it on in System Settings, under Privacy and Security, Camera."
        case .noCamera: return "I can't find a camera on this Mac."
        case .timedOut: return "The camera didn't give me a picture in time."
        case .noFrame(let source): return "There is no recent picture from the \(source)."
        case .unknownSource(let s): return "I don't have a camera source called “\(s)”."
        }
    }
}

/// Anything that can hand Jarvis a picture on demand. The Mac's camera today; a glasses bridge later.
/// Sources never run on their own: `captureFrame` is called once per request, when the user asks Jarvis to look.
public protocol FrameSource: AnyObject, Sendable {
    /// Short name used in the tool input and in the action log.
    var name: String { get }
    func captureFrame() async throws -> Frame
}

/// A source that is fed from outside: a bridge (glasses, a phone) pushes its newest frame, and Jarvis reads
/// it when asked. This is the hook for the glasses bridge in the remote-access phase.
/// A frame older than `maxAge` is refused, so Jarvis never describes a stale view as "what you're looking at".
public final class PushedFrameSource: FrameSource, @unchecked Sendable {
    public let name: String
    public var maxAge: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var latest: Frame?

    public init(name: String = "glasses", maxAge: TimeInterval = 10, now: @escaping () -> Date = Date.init) {
        self.name = name; self.maxAge = maxAge; self.now = now
    }

    /// Called by the bridge. Only the newest frame is kept, in memory.
    public func push(jpeg: Data, width: Int, height: Int) {
        lock.lock(); latest = Frame(jpeg: jpeg, width: width, height: height, source: name, capturedAt: now()); lock.unlock()
    }

    /// The newest pushed frame, if any.
    public var newest: Frame? { lock.lock(); defer { lock.unlock() }; return latest }

    public func captureFrame() async throws -> Frame {
        guard let f = newest, now().timeIntervalSince(f.capturedAt) <= maxAge else { throw VisionError.noFrame(name) }
        return f
    }
}

/// The frame sources Jarvis knows about, by name.
public final class FrameSources: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [String: any FrameSource] = [:]
    public private(set) var defaultName: String

    public init(_ list: [any FrameSource], default defaultName: String? = nil) {
        for s in list { sources[s.name] = s }
        self.defaultName = defaultName ?? list.first?.name ?? "camera"
    }

    public func register(_ source: any FrameSource) { lock.lock(); sources[source.name] = source; lock.unlock() }
    public var names: [String] { lock.lock(); defer { lock.unlock() }; return sources.keys.sorted() }

    public func source(named name: String?) throws -> any FrameSource {
        let wanted = (name?.isEmpty ?? true) ? defaultName : name!
        lock.lock(); defer { lock.unlock() }
        guard let s = sources[wanted] else { throw VisionError.unknownSource(wanted) }
        return s
    }
}

/// The Mac's own camera. Opens it, lets exposure settle, takes one frame, and closes it again.
/// The camera is on for about a second; macOS shows the green indicator while it is.
public final class CameraFrameSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let name = "camera"
    /// Longest side of the picture sent to the model. Bigger costs more tokens for little gain.
    public var maxSide: CGFloat = 1280
    public var jpegQuality: CGFloat = 0.7
    /// Frames to let pass first so auto-exposure and white balance settle.
    public var warmupFrames = 12
    public var timeout: TimeInterval = 6

    private let queue = DispatchQueue(label: "com.samarth.jarvis.camera")
    private let context = CIContext()
    private var session: AVCaptureSession?
    private var seen = 0
    private var waiting: CheckedContinuation<Frame, Error>?

    public override init() { super.init() }

    public func captureFrame() async throws -> Frame {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined: guard await AVCaptureDevice.requestAccess(for: .video) else { throw VisionError.cameraDenied }
        default: throw VisionError.cameraDenied
        }
        // Prefer the Mac's own camera over a nearby iPhone (Continuity Camera).
        let builtIn = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices.first
        guard let device = builtIn ?? AVCaptureDevice.default(for: .video) else { throw VisionError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Frame, Error>) in
            queue.async { [self] in
                guard waiting == nil else { cont.resume(throwing: VisionError.timedOut); return }   // one capture at a time
                let s = AVCaptureSession()
                if s.canSetSessionPreset(.hd1280x720) { s.sessionPreset = .hd1280x720 }
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                guard s.canAddInput(input), s.canAddOutput(output) else { cont.resume(throwing: VisionError.noCamera); return }
                s.addInput(input); s.addOutput(output)
                session = s; seen = 0; waiting = cont
                s.startRunning()
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(VisionError.timedOut), from: s) }
            }
        }
    }

    /// Queue only. Resumes the waiting caller once and turns the camera off.
    private func finish(_ result: Result<Frame, Error>, from s: AVCaptureSession) {
        guard session === s, let cont = waiting else { return }
        waiting = nil
        session = nil
        s.stopRunning()
        cont.resume(with: result)
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let s = session, waiting != nil else { return }
        seen += 1
        guard seen > warmupFrames, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var image = CIImage(cvPixelBuffer: pixels)
        let side = max(image.extent.width, image.extent.height)
        if side > maxSide { image = image.transformed(by: CGAffineTransform(scaleX: maxSide / side, y: maxSide / side)) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = context.jpegRepresentation(of: image, colorSpace: space,
                                                    options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): jpegQuality]) else {
            finish(.failure(VisionError.noFrame(name)), from: s)
            return
        }
        finish(.success(Frame(jpeg: jpeg, width: Int(image.extent.width), height: Int(image.extent.height), source: name)), from: s)
    }
}
