import Foundation
import LocalAuthentication

/// The passive lock: personal features work only while the owner is at the Mac.
/// Today it listens to the camera; the phone check joins it in the same place.
@MainActor
public final class OwnerLock {
    /// Tools that touch nothing personal. Everything NOT listed here is treated as personal, so a tool
    /// added later is locked until someone decides otherwise.
    public static let generalTools: Set<String> = [
        "app_health", "camera", "google_search", "lights", "look", "media_control", "music", "news_headlines",
        "open_app", "open_website", "owner_lock", "performance_report", "restart_app", "set_brightness",
        "set_display_mode", "set_focus", "set_mode", "set_timer", "set_volume", "speech_speed", "system_status", "weather",
    ]

    public struct Settings: Equatable, Sendable {
        public var enabled = false
        /// How long a tool call waits for the camera to make up its mind.
        public var decisionSeconds: TimeInterval = 4
        /// How long a Touch ID unlock lasts.
        public var overrideMinutes: Double = 10
        public init() {}
    }

    public var settings: () -> Settings
    public var isEnrolled: () -> Bool
    private let watcher: FaceWatcher?
    private let authenticate: (String) async -> Bool
    private let log: FaceLog
    private let now: () -> Date
    public private(set) var overrideUntil: Date?
    /// Told whenever the lock opens or closes by hand, for the menu.
    public var onChange: (() -> Void)?

    public init(watcher: FaceWatcher?, settings: @escaping () -> Settings, isEnrolled: @escaping () -> Bool,
                authenticate: @escaping (String) async -> Bool = OwnerLock.touchID, log: FaceLog = FaceLog(), now: @escaping () -> Date = Date.init) {
        self.watcher = watcher; self.settings = settings; self.isEnrolled = isEnrolled
        self.authenticate = authenticate; self.log = log; self.now = now
    }

    /// The lock only does anything once it is switched on AND a face is enrolled.
    public var isActive: Bool { settings().enabled && isEnrolled() }
    public var overrideActive: Bool { overrideUntil.map { $0 > now() } ?? false }

    public static func isPersonal(_ tool: String) -> Bool { !generalTools.contains(tool) }

    /// Nil when the call may go ahead; otherwise the sentence that says why not.
    public func refusal(tool: String, fromPhone: Bool) async -> String? {
        guard isActive, Self.isPersonal(tool), !fromPhone, !overrideActive else { return nil }
        let v = await look(wait: settings().decisionSeconds)
        return v.ownerPresent ? nil : Self.explain(v)
    }

    /// Whether personal context (memory, earlier conversation, profile facts) must be kept out of a request.
    public func personalDataLocked(fromPhone: Bool, wait: TimeInterval = 2.5) async -> Bool {
        guard isActive, !fromPhone, !overrideActive else { return false }
        return !(await look(wait: wait)).ownerPresent
    }

    /// Looks through the camera, starting it for a moment if no conversation has it on.
    private func look(wait: TimeInterval) async -> FaceWatcher.Verdict {
        guard let watcher else { return .init(state: .error, ownerPresent: false, detail: "no camera watcher", score: nil) }
        let holder = "gate-\(UUID().uuidString)"
        watcher.begin(holder)
        defer { watcher.end(holder) }
        return await watcher.settledVerdict(wait: wait)
    }

    nonisolated static func explain(_ v: FaceWatcher.Verdict) -> String {
        let how = " Sam can say \"unlock with Touch ID\" or use the menu. Say this in one short sentence and do not retry."
        switch v.state {
        case .unknown: return "Locked: the face check failed. The camera sees someone it does not recognise as Sam, so personal data stays closed." + how
        case .noFace, .idle: return "Locked: the face check failed. The camera cannot see a face." + how
        case .checking:
            return "Locked: the face check is not finished. " + (v.detail.contains("blink") ? "The face looks right but has not blinked or moved yet; Sam should blink or turn his head a little and ask again." : "Sam should look at the camera and ask again.") + how
        case .error: return "Locked: the face check could not run (\(v.detail)), and when it cannot run everything personal stays closed." + how
        case .owner: return "Locked." + how
        }
    }

    // MARK: Manual override

    /// Touch ID opens the lock for a few minutes when the camera cannot do its job.
    @discardableResult
    public func unlockWithTouchID() async -> Bool {
        guard await authenticate("unlock Jarvis's personal features") else {
            log.record("override-refused", detail: "Touch ID not confirmed", at: now())
            return false
        }
        let minutes = max(1, settings().overrideMinutes)
        overrideUntil = now().addingTimeInterval(minutes * 60)
        log.record("override-on", detail: "Touch ID, \(Int(minutes)) min", at: now())
        onChange?()
        return true
    }

    /// Close it again now: ends a Touch ID unlock and forgets the owner was just seen.
    public func lockNow() {
        overrideUntil = nil
        watcher?.forgetOwner()
        log.record("locked-by-hand", at: now())
        onChange?()
    }

    /// For anything that changes the lock itself (enrolling a face, switching it off): Touch ID, every time.
    public func confirmOwner(_ reason: String) async -> Bool { await authenticate(reason) }

    /// Touch ID only: no password fallback, so knowing the Mac's password is not enough.
    public nonisolated static func touchID(_ reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            JarvisLog.warn("Owner lock: Touch ID is not available (\(error?.localizedDescription ?? "unknown"))")
            return false
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) ?? false
    }
}
