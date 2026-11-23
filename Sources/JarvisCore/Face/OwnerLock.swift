import Foundation
import LocalAuthentication

/// How much of Jarvis is open right now.
public enum Access: Int, Comparable, Sendable {
    case general    // nothing personal
    case limited    // one of two checks passed: the calendar, reminders, notes, memory
    case full       // every check passed
    public static func < (a: Access, b: Access) -> Bool { a.rawValue < b.rawValue }
}

/// The passive lock: personal features work only while the owner is at the Mac.
/// Two checks feed it, each optional: the face (camera) and the phone (Bluetooth).
@MainActor
public final class OwnerLock {
    /// Tools that touch nothing personal. They always work.
    public static let generalTools: Set<String> = [
        "app_health", "camera", "google_search", "lights", "look", "media_control", "music", "news_headlines",
        "open_app", "open_website", "owner_lock", "performance_report", "restart_app", "set_brightness",
        "set_display_mode", "set_focus", "set_mode", "set_timer", "set_volume", "speech_speed", "system_status", "weather",
    ]
    /// Personal but low-risk: these still work when only one of two checks passes.
    public static let limitedTools: Set<String> = [
        "actions_today", "calendar_create", "calendar_read", "contacts", "devices", "get_location_context", "memory",
        "memory_search", "notion_create_note", "notion_search", "remember_place", "set_reminder", "undo_last_action",
    ]

    /// What a tool needs. Anything in neither list is sensitive (email, files, briefings, shell, computer
    /// control, anything that sends or deletes), so a tool added later is fully locked until someone decides.
    public static func level(of tool: String) -> Access {
        generalTools.contains(tool) ? .general : limitedTools.contains(tool) ? .limited : .full
    }
    public static func isPersonal(_ tool: String) -> Bool { level(of: tool) != .general }

    /// One check's answer.
    public struct Factor: Equatable, Sendable {
        public var name: String        // "face" or "phone"
        public var passed: Bool
        /// A veto closes everything personal whatever the other check says (an unknown face at the Mac).
        public var veto = false
        public var why: String
        public init(name: String, passed: Bool, veto: Bool = false, why: String) { self.name = name; self.passed = passed; self.veto = veto; self.why = why }
    }

    /// The rule: all checks pass → full. Some pass → limited. None, or any veto → general.
    public nonisolated static func access(_ factors: [Factor]) -> Access {
        guard !factors.isEmpty else { return .full }
        if factors.contains(where: \.veto) { return .general }
        let passed = factors.filter(\.passed).count
        return passed == factors.count ? .full : passed > 0 ? .limited : .general
    }

    public struct Settings: Equatable, Sendable {
        public var faceRequired = false
        public var phoneRequired = false
        /// How long a tool call waits for the camera to make up its mind.
        public var decisionSeconds: TimeInterval = 4
        /// How long a Touch ID unlock lasts.
        public var overrideMinutes: Double = 10
        public init() {}
    }

    public var settings: () -> Settings
    public var isEnrolled: () -> Bool
    /// The phone check, when a phone has been chosen. Nil: no phone is set up.
    public var phone: (() -> PhoneRadar.Check?)?
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

    /// The face check counts once it is switched on AND a face is enrolled.
    public var faceActive: Bool { settings().faceRequired && isEnrolled() }
    /// The phone check counts once it is switched on AND a phone has been chosen.
    public var phoneActive: Bool { settings().phoneRequired && phone?() != nil }
    public var isActive: Bool { faceActive || phoneActive }
    public var overrideActive: Bool { overrideUntil.map { $0 > now() } ?? false }

    /// Runs every check that is switched on. The phone is asked first: it needs no camera.
    public func factors(wait: TimeInterval) async -> [Factor] {
        var out: [Factor] = []
        if phoneActive, let p = phone?() { out.append(Factor(name: "phone", passed: p.near, why: p.why)) }
        if faceActive {
            let v = await look(wait: wait)
            out.append(Factor(name: "face", passed: v.ownerPresent, veto: v.state == .unknown, why: Self.describe(v)))
        }
        return out
    }

    /// How much is open right now.
    public func access(fromPhone: Bool, wait: TimeInterval) async -> (access: Access, factors: [Factor]) {
        guard isActive, !fromPhone, !overrideActive else { return (.full, []) }
        let f = await factors(wait: wait)
        return (Self.access(f), f)
    }

    private var lastLogged: String?
    /// Nil when the call may go ahead; otherwise the sentence that says why not.
    public func refusal(tool: String, fromPhone: Bool) async -> String? {
        let need = Self.level(of: tool)
        guard need != .general, isActive, !fromPhone, !overrideActive else { return nil }
        let (have, factors) = await access(fromPhone: false, wait: settings().decisionSeconds)
        // One line in face.log whenever the combined answer changes, so a false lock can be traced.
        let summary = "\(have) " + factors.map { "\($0.name)=\($0.passed ? "ok" : $0.veto ? "veto" : "no")" }.joined(separator: " ")
        if summary != lastLogged { lastLogged = summary; log.record("access", detail: summary, at: now()) }
        return have >= need ? nil : Self.explain(have: have, need: need, factors: factors)
    }

    /// Whether personal context (memory, earlier conversation, profile facts) must be kept out of a request.
    public func personalDataLocked(fromPhone: Bool, wait: TimeInterval = 2.5) async -> Bool {
        await access(fromPhone: fromPhone, wait: wait).access == .general
    }

    /// Looks through the camera, starting it for a moment if no conversation has it on.
    private func look(wait: TimeInterval) async -> FaceWatcher.Verdict {
        guard let watcher else { return .init(state: .error, ownerPresent: false, detail: "no camera watcher", score: nil) }
        let holder = "gate-\(UUID().uuidString)"
        watcher.begin(holder)
        defer { watcher.end(holder) }
        return await watcher.settledVerdict(wait: wait)
    }

    nonisolated static func describe(_ v: FaceWatcher.Verdict) -> String {
        switch v.state {
        case .owner: return "the camera sees Sam"
        case .unknown: return "the camera sees someone it does not recognise as Sam"
        case .noFace, .idle: return v.ownerPresent ? "no face in view, but Sam was seen a moment ago" : "the camera cannot see a face"
        case .checking: return v.detail.contains("blink") ? "the face looks right but has not blinked or moved yet (blink or turn the head a little and ask again)" : "the camera has not made out a face yet (look at the camera and ask again)"
        case .error: return "the face check could not run (\(v.detail)), and when it cannot run it counts as failed"
        }
    }

    nonisolated static func explain(have: Access, need: Access, factors: [Factor]) -> String {
        let failed = factors.filter { !$0.passed }
        var s = "Locked: the \(failed.map(\.name).joined(separator: " and ")) check failed. " + failed.map { $0.why.prefix(1).uppercased() + $0.why.dropFirst() + "." }.joined(separator: " ")
        if have == .limited, need == .full {
            let ok = factors.filter(\.passed).map(\.name).joined(separator: " and ")
            s += " Only the \(ok) check passed, so the calendar, reminders, notes and memory work, but email, files, briefings and anything that sends, deletes or runs commands stay closed."
        } else {
            s += " Personal data stays closed."
        }
        return s + " Sam can say \"unlock with Touch ID\" or use the menu. Say which check failed in one short sentence and do not retry."
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
