import AVFoundation
import CoreImage
import Foundation

/// A finished video.
public struct Recording: Equatable, Sendable {
    public var url: URL
    public var seconds: Double
    public var bytes: Int
    public init(url: URL, seconds: Double, bytes: Int) { self.url = url; self.seconds = seconds; self.bytes = bytes }
}

/// The one camera session everything shares: the live feed, single frames for `look`, photos, and video.
///
/// The camera runs only while something holds it. Each user (the feed window, a recording, one frame grab)
/// acquires it under a name and releases it when done; when the last holder lets go, the camera turns off.
/// All AVFoundation work happens on one private queue.
public final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    /// For the preview layer. Do not configure it from outside.
    public let session = AVCaptureSession()

    /// A recording that ended without `stopRecording` being called: the time limit, a full disk, a lost camera.
    public var onRecordingEndedByItself: ((Result<Recording, Error>) -> Void)?

    private let queue = DispatchQueue(label: "com.samarth.jarvis.camera")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let ciContext = CIContext()
    private var configured = false
    private var holders = Set<String>()
    private var audioInput: AVCaptureDeviceInput?

    private struct Grab { let cont: CheckedContinuation<Frame, Error>; var skip: Int; let maxSide: CGFloat; let quality: CGFloat; let source: String; let token: UUID }
    private var grab: Grab?
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var stopWaiter: CheckedContinuation<Recording, Error>?
    private var recordingStartedAt: Date?

    public override init() { super.init() }

    public static func ensureAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined: guard await AVCaptureDevice.requestAccess(for: .video) else { throw VisionError.cameraDenied }
        default: throw VisionError.cameraDenied
        }
    }

    // MARK: Holding the camera

    /// Turns the camera on if it is off. Returns true when it was already running (no warm-up needed).
    @discardableResult
    public func acquire(_ holder: String) async throws -> Bool {
        try await Self.ensureAccess()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            queue.async { [self] in
                do {
                    try configureIfNeeded()
                    let wasRunning = session.isRunning
                    holders.insert(holder)
                    if !wasRunning { session.startRunning() }
                    set(running: true)
                    cont.resume(returning: wasRunning)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Lets go. The camera turns off when nobody holds it.
    public func release(_ holder: String) {
        queue.async { [self] in
            holders.remove(holder)
            guard holders.isEmpty, session.isRunning, !movieOutput.isRecording else { return }
            set(running: false)      // before the slow call: the camera is on its way off
            session.stopRunning()
            if let a = audioInput {
                session.beginConfiguration(); session.removeInput(a); session.commitConfiguration()
                audioInput = nil
            }
        }
    }

    // State readable from any thread without touching the camera queue. Reading it with `queue.sync` from
    // the main thread deadlocked the app on 2026-11-22: stopRunning() on the camera queue waits for the
    // main thread, which was waiting for the camera queue.
    private let stateLock = NSLock()
    private var runningFlag = false
    private var recordingFlag = false
    public var isRunning: Bool { stateLock.lock(); defer { stateLock.unlock() }; return runningFlag }
    public var isRecording: Bool { stateLock.lock(); defer { stateLock.unlock() }; return recordingFlag }
    private func set(running: Bool? = nil, recording: Bool? = nil) {
        stateLock.lock()
        if let running { runningFlag = running }
        if let recording { recordingFlag = recording }
        stateLock.unlock()
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        // Prefer the Mac's own camera over a nearby iPhone (Continuity Camera).
        let builtIn = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices.first
        guard let device = builtIn ?? AVCaptureDevice.default(for: .video) else { throw VisionError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        guard session.canAddInput(input) else { throw VisionError.noCamera }
        session.addInput(input)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(videoOutput) else { throw VisionError.noCamera }
        session.addOutput(videoOutput)
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        configured = true
    }

    // MARK: One frame

    /// The next usable frame as a JPEG. `skip` frames pass first so exposure can settle after a cold start.
    public func grabFrame(skip: Int, maxSide: CGFloat, quality: CGFloat, source: String = "camera", timeout: TimeInterval = 6) async throws -> Frame {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Frame, Error>) in
            queue.async { [self] in
                guard grab == nil else { cont.resume(throwing: VisionError.timedOut); return }   // one grab at a time
                let token = UUID()
                grab = Grab(cont: cont, skip: max(0, skip), maxSide: maxSide, quality: quality, source: source, token: token)
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    guard let g = grab, g.token == token else { return }
                    grab = nil
                    g.cont.resume(throwing: VisionError.timedOut)
                }
            }
        }
    }

    /// Lets one named watcher see every frame while the camera runs (the face check). Pass nil to stop.
    /// The closure runs on the camera queue: it must be quick and must not keep the buffer.
    public func setFrameTap(_ name: String, _ tap: ((CVPixelBuffer) -> Void)?) {
        queue.async { [self] in taps[name] = tap }
    }
    private var taps: [String: (CVPixelBuffer) -> Void] = [:]

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if !taps.isEmpty, output === videoOutput, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
            for tap in taps.values { tap(pixels) }
        }
        guard var g = grab else { return }
        if g.skip > 0 { g.skip -= 1; grab = g; return }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        grab = nil
        var image = CIImage(cvPixelBuffer: pixels)
        let side = max(image.extent.width, image.extent.height)
        if side > g.maxSide { image = image.transformed(by: CGAffineTransform(scaleX: g.maxSide / side, y: g.maxSide / side)) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: space,
                                                      options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): g.quality]) else {
            g.cont.resume(throwing: VisionError.noFrame(g.source))
            return
        }
        g.cont.resume(returning: Frame(jpeg: jpeg, width: Int(image.extent.width), height: Int(image.extent.height), source: g.source))
    }

    // MARK: Video

    /// Starts writing a movie. Returns once the file is actually being written. Stops by itself at `maxSeconds`.
    public func startRecording(to url: URL, audio: Bool, maxSeconds: Double) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard session.isRunning, session.outputs.contains(movieOutput) else { cont.resume(throwing: VisionError.recordingFailed("the camera is not running")); return }
                guard !movieOutput.isRecording, startWaiter == nil else { cont.resume(throwing: VisionError.alreadyRecording); return }
                session.beginConfiguration()
                if audio, audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
                   let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
                    session.addInput(input)
                    audioInput = input
                } else if !audio, let a = audioInput {
                    session.removeInput(a)
                    audioInput = nil
                }
                session.commitConfiguration()
                movieOutput.maxRecordedDuration = maxSeconds > 0 ? CMTime(seconds: maxSeconds, preferredTimescale: 600) : .invalid
                startWaiter = cont
                set(recording: true)
                movieOutput.startRecording(to: url, recordingDelegate: self)
            }
        }
    }

    /// Finishes the movie and returns it.
    public func stopRecording() async throws -> Recording {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Recording, Error>) in
            queue.async { [self] in
                guard movieOutput.isRecording, stopWaiter == nil else { cont.resume(throwing: VisionError.notRecording); return }
                stopWaiter = cont
                movieOutput.stopRecording()
            }
        }
    }

    public func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        queue.async { [self] in
            recordingStartedAt = Date()
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let recorded = output.recordedDuration.seconds
        queue.async { [self] in
            // Reaching the time limit arrives as an "error" whose file is nonetheless complete.
            let finishedCleanly = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
            let started = recordingStartedAt
            recordingStartedAt = nil
            set(recording: false)
            let result: Result<Recording, Error>
            if finishedCleanly {
                let seconds = recorded.isFinite && recorded > 0 ? recorded : Date().timeIntervalSince(started ?? Date())
                let bytes = ((try? FileManager.default.attributesOfItem(atPath: outputFileURL.path))?[.size] as? Int) ?? 0
                result = .success(Recording(url: outputFileURL, seconds: seconds, bytes: bytes))
            } else {
                result = .failure(VisionError.recordingFailed(error?.localizedDescription ?? "unknown error"))
            }
            if let s = startWaiter {            // it never got going
                startWaiter = nil
                if case .failure(let e) = result { s.resume(throwing: e) } else { s.resume() }
            }
            if let w = stopWaiter {
                stopWaiter = nil
                w.resume(with: result)
            } else {
                onRecordingEndedByItself?(result)
            }
            if holders.isEmpty, session.isRunning { set(running: false); session.stopRunning() }
        }
    }
}
