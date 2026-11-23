import CoreGraphics
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
    case alreadyRecording
    case notRecording
    case recordingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cameraDenied: return "I don't have camera access. Turn it on in System Settings, under Privacy and Security, Camera."
        case .noCamera: return "I can't find a camera on this Mac."
        case .timedOut: return "The camera didn't give me a picture in time."
        case .noFrame(let source): return "There is no recent picture from the \(source)."
        case .unknownSource(let s): return "I don't have a camera source called “\(s)”."
        case .alreadyRecording: return "I'm already recording."
        case .notRecording: return "I'm not recording anything right now."
        case .recordingFailed(let why): return "The recording failed: \(why)."
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

/// One frame from the Mac's camera, for `look`. It borrows the shared `CameraSession`: if the live feed is
/// already on, the next frame is used; otherwise the camera opens, exposure settles, one frame is taken,
/// and the camera closes again (about a second, with the green indicator on).
public final class CameraFrameSource: FrameSource, @unchecked Sendable {
    public let name = "camera"
    /// Longest side of the picture sent to the model. Bigger costs more tokens for little gain.
    public var maxSide: CGFloat = 1280
    public var jpegQuality: CGFloat = 0.7
    /// Frames to let pass after a cold start so auto-exposure and white balance settle.
    public var warmupFrames = 12
    private let session: CameraSession

    public init(session: CameraSession) { self.session = session }

    public func captureFrame() async throws -> Frame {
        let holder = "look-\(UUID().uuidString)"
        let wasRunning = try await session.acquire(holder)
        defer { session.release(holder) }
        return try await session.grabFrame(skip: wasRunning ? 1 : warmupFrames, maxSide: maxSide, quality: jpegQuality, source: name)
    }
}
