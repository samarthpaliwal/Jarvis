import AppKit
import AVFoundation
import Foundation

/// Where pictures and videos go: folders Jarvis creates and owns.
public enum CameraFiles {
    public enum Kind { case video, photo }

    public static func directory(_ kind: Kind, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(kind == .video ? "Movies/Jarvis" : "Pictures/Jarvis", isDirectory: true)
    }

    /// "Jarvis 2026-11-22 at 23.41.05.mov"
    public static func url(_ kind: Kind, now: Date = Date(), home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return directory(kind, home: home).appendingPathComponent("Jarvis \(f.string(from: now)).\(kind == .video ? "mov" : "jpg")")
    }

    /// "Movies/Jarvis/Jarvis 2026-11-22 at 23.41.05.mov", for speech and cards.
    public static func display(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        url.path.hasPrefix(home.path + "/") ? String(url.path.dropFirst(home.path.count + 1)) : url.path
    }

    /// The limit a recording really gets: the request, capped by the configured maximum.
    public static func recordingLimit(requested: Double?, maximum: Double) -> Double {
        let cap = maximum > 0 ? maximum : 300
        guard let r = requested, r > 0 else { return cap }
        return min(r, cap)
    }

    public static func spokenLength(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)-second" }
        let m = s / 60, rest = s % 60
        return rest == 0 ? "\(m)-minute" : "\(m)-minute \(rest)-second"
    }
}

/// What the camera tool and the menu drive. The real one is `CameraController`; tests use a fake.
@MainActor
public protocol CameraControlling: AnyObject {
    var isFeedVisible: Bool { get }
    var isRecording: Bool { get }
    /// Opens the live feed window. The camera stays on while it is open.
    func showFeed() async throws
    /// Closes the feed. A recording in progress is stopped and returned.
    @discardableResult func hideFeed() async -> Recording?
    /// Saves one still to Pictures/Jarvis.
    func takePhoto() async throws -> URL
    /// Starts a video in Movies/Jarvis. Always opens the feed, so a recording is never invisible.
    func startRecording(seconds: Double?, audio: Bool) async throws -> (url: URL, limit: Double)
    func stopRecording() async throws -> Recording
}

/// The live feed window: the camera, mirrored like a mirror, with a red badge while recording.
@MainActor
final class CameraFeedWindow: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var badge: NSTextField?
    private var timer: Timer?
    private var closingOurselves = false
    var onClosedByUser: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(session: AVCaptureSession) {
        if panel == nil { build(session) }
        panel?.orderFrontRegardless()
    }

    func hide() {
        closingOurselves = true
        panel?.close()
        closingOurselves = false
        setRecording(since: nil)
    }

    /// Shows "● REC 0:12" while `since` is set.
    func setRecording(since: Date?) {
        timer?.invalidate(); timer = nil
        guard let since else { badge?.isHidden = true; panel?.title = "Jarvis Camera"; return }
        let tick = { [weak self] in
            let s = Int(Date().timeIntervalSince(since))
            self?.badge?.stringValue = String(format: " ● REC %d:%02d ", s / 60, s % 60)
        }
        tick()
        badge?.isHidden = false
        panel?.title = "Jarvis Camera (recording)"
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in Task { @MainActor in tick() } }
    }

    private func build(_ session: AVCaptureSession) {
        let size = NSSize(width: 480, height: 270)
        let visible = ScreenResolver.target(pinned: nil)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 48)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "Jarvis Camera"
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentAspectRatio = NSSize(width: 16, height: 9)
        p.contentMinSize = NSSize(width: 240, height: 135)
        p.delegate = self

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspect
        preview.frame = container.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // A self-view reads naturally when mirrored. Recordings and photos are not mirrored.
        if let c = preview.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        container.layer?.addSublayer(preview)

        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.drawsBackground = true
        label.backgroundColor = NSColor.systemRed
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
                                     label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10)])
        p.contentView = container
        badge = label
        panel = p
    }

    func windowWillClose(_ notification: Notification) {
        if !closingOurselves { onClosedByUser?() }
    }
}

/// Live feed, photos, and video on top of one shared `CameraSession`.
///
/// The rule that keeps recording honest: a video can only be recorded while the feed window is open and
/// shows its red badge. Closing the window stops the recording and turns the camera off.
@MainActor
public final class CameraController: CameraControlling {
    public let session: CameraSession
    private let window = CameraFeedWindow()
    /// Longest recording allowed, in seconds. Read each time a recording starts.
    public var maxRecordingSeconds: () -> Double = { 300 }
    /// Something the user should hear: a recording stopped at its limit, or failed.
    public var onNotice: ((String) -> Void)?
    public private(set) var lastRecording: Recording?

    public init(session: CameraSession = CameraSession()) {
        self.session = session
        window.onClosedByUser = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let r = await self.closeFeed() { self.onNotice?("Recording stopped. I saved a \(CameraFiles.spokenLength(r.seconds)) video.") }
            }
        }
        session.onRecordingEndedByItself = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.window.setRecording(since: nil)
                switch result {
                case .success(let r):
                    self.lastRecording = r
                    JarvisLog.info("Camera: recording reached its limit; saved \(CameraFiles.display(r.url)) (\(Int(r.seconds)) s, \(r.bytes / 1024) KB)")
                    self.onNotice?("The recording reached its time limit. I saved a \(CameraFiles.spokenLength(r.seconds)) video.")
                case .failure(let e):
                    JarvisLog.error("Camera: recording failed: \(e.localizedDescription)")
                    self.onNotice?("The recording stopped: \(e.localizedDescription)")
                }
            }
        }
    }

    public var isFeedVisible: Bool { window.isVisible }
    public var isRecording: Bool { session.isRecording }

    public func showFeed() async throws {
        guard !window.isVisible else { return }
        try await session.acquire("feed")
        window.show(session: session.session)
        JarvisLog.info("Camera: live feed opened")
    }

    @discardableResult
    public func hideFeed() async -> Recording? {
        window.hide()
        return await closeFeed()
    }

    /// Stops any recording, then lets go of the camera.
    private func closeFeed() async -> Recording? {
        var finished: Recording?
        if session.isRecording {
            finished = try? await session.stopRecording()
            if let r = finished {
                lastRecording = r
                JarvisLog.info("Camera: feed closed, recording saved \(CameraFiles.display(r.url)) (\(Int(r.seconds)) s)")
            }
        }
        window.setRecording(since: nil)
        session.release("feed")
        JarvisLog.info("Camera: live feed closed")
        return finished
    }

    public func takePhoto() async throws -> URL {
        let holder = "photo-\(UUID().uuidString)"
        let wasRunning = try await session.acquire(holder)
        defer { session.release(holder) }
        let frame = try await session.grabFrame(skip: wasRunning ? 1 : 12, maxSide: 1920, quality: 0.9)
        let url = CameraFiles.url(.photo)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try frame.jpeg.write(to: url, options: .atomic)
        JarvisLog.info("Camera: photo saved \(CameraFiles.display(url)) (\(frame.width)×\(frame.height), \(frame.jpeg.count / 1024) KB)")
        return url
    }

    public func startRecording(seconds: Double?, audio: Bool) async throws -> (url: URL, limit: Double) {
        guard !session.isRecording else { throw VisionError.alreadyRecording }
        try await showFeed()                                   // never record without the window
        let limit = CameraFiles.recordingLimit(requested: seconds, maximum: maxRecordingSeconds())
        let url = CameraFiles.url(.video)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await session.startRecording(to: url, audio: audio, maxSeconds: limit)
        window.setRecording(since: Date())
        JarvisLog.info("Camera: recording to \(CameraFiles.display(url)), limit \(Int(limit)) s, audio \(audio)")
        return (url, limit)
    }

    public func stopRecording() async throws -> Recording {
        let r = try await session.stopRecording()
        window.setRecording(since: nil)
        lastRecording = r
        JarvisLog.info("Camera: recording saved \(CameraFiles.display(r.url)) (\(Int(r.seconds)) s, \(r.bytes / 1024) KB)")
        return r
    }
}
