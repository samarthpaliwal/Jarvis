import AppKit
import Foundation

/// Morning briefing, exam/deadline nudges, break reminders, quiet hours, low battery on the road.
/// Everything here is Tier 0/1 by construction and gated by DND, quiet hours, and call detection.
@MainActor
public final class ProactiveScheduler: ObservableObject {
    public struct Status: Equatable {
        public var briefingDeliveredOn: String?
        public var lastNudge: String?
        public var codingMinutes: Int = 0
        public var suppressedBy: String?
    }
    @Published public private(set) var status = Status()

    private let config: ConfigStore
    private let modes: ModeManager
    private let notch: NotchViewModel
    private let briefing: BriefingService
    private let deliver: (String, [NotchCard]) -> Void
    private var timer: Timer?
    private var observers: [Any] = []
    private let defaults = UserDefaults.standard
    private var codingSince: Date?
    private var lastBreakNudge = Date.distantPast
    private var lastBatteryWarn = Date.distantPast
    private var lastNudgeCheck = Date.distantPast

    public static let codingApps = ["Xcode", "Code", "Visual Studio Code", "Cursor", "Terminal", "iTerm2", "Warp", "Ghostty", "IntelliJ IDEA", "PyCharm", "Android Studio", "Zed", "Claude"]

    public init(config: ConfigStore, modes: ModeManager, notch: NotchViewModel, briefing: BriefingService,
                deliver: @escaping (String, [NotchCard]) -> Void) {
        self.config = config; self.modes = modes; self.notch = notch; self.briefing = briefing; self.deliver = deliver
        status.briefingDeliveredOn = defaults.string(forKey: "jarvis.briefingDeliveredOn")
    }

    public func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.onUnlock() }
        })
        Task { await tick() }
    }

    // MARK: Gates

    public var isQuietHours: Bool {
        let p = config.profile.proactive
        return Self.inWindow(start: p.quietHoursStart, end: p.quietHoursEnd, now: Date())
    }

    /// Why we must stay silent right now, or nil.
    public func suppression() -> String? {
        if notch.doNotDisturb { return "Do Not Disturb" }
        if isQuietHours { return "quiet hours" }
        if PresenceDetector.isInCallOrSharing(callApps: config.profile.proactive.callApps) { return "in a call or sharing" }
        if modes.current.holdNotifications && modes.current.id == "class" { return "class mode" }
        return nil
    }

    nonisolated static func inWindow(start: String, end: String, now: Date) -> Bool {
        func minutes(_ s: String) -> Int { let p = s.split(separator: ":"); return (Int(p.first ?? "0") ?? 0) * 60 + (Int(p.count > 1 ? p[1] : "0") ?? 0) }
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let a = minutes(start), b = minutes(end)
        return a <= b ? (m >= a && m < b) : (m >= a || m < b)
    }

    // MARK: Tick

    func tick() async {
        status.suppressedBy = suppression()
        trackCoding()
        await maybeMorningBriefing(trigger: "time")
        await maybeNudges()
        maybeBatteryWarning()
        maybeBreakReminder()
    }

    private func onUnlock() async {
        guard config.profile.briefing.onFirstUnlock else { return }
        await maybeMorningBriefing(trigger: "unlock")
    }

    private var todayKey: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }

    private func maybeMorningBriefing(trigger: String) async {
        guard status.briefingDeliveredOn != todayKey else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        let due = Self.inWindow(start: config.profile.briefing.time, end: "23:59", now: Date())
        guard due || (trigger == "unlock" && hour >= 5) else { return }
        guard suppression() == nil else { return }
        let r = await briefing.build(mode: modes.current)
        status.briefingDeliveredOn = todayKey
        defaults.set(todayKey, forKey: "jarvis.briefingDeliveredOn")
        JarvisLog.info("Morning briefing delivered (\(trigger))")
        deliver(r.spoken, [.briefing(r.data)])
    }

    /// Exam/deadline countdowns at the configured day marks, each said once.
    private func maybeNudges() async {
        guard Date().timeIntervalSince(lastNudgeCheck) > 30 * 60, suppression() == nil else { return }
        lastNudgeCheck = Date()
        let r = await briefing.build(mode: modes.current)
        let marks = Set(config.profile.briefing.nudgeDaysBefore)
        var lines: [String] = []
        for item in r.data.exams + r.data.deadlines {
            guard let d = item.daysLeft, marks.contains(d) else { continue }
            let key = "jarvis.nudge.\(item.title.lowercased()).\(d)"
            guard !defaults.bool(forKey: key) else { continue }
            defaults.set(true, forKey: key)
            lines.append("\(item.title) is \(d == 0 ? "today" : d == 1 ? "tomorrow" : "in \(d) days")")
            if lines.count == 2 { break }
        }
        guard !lines.isEmpty else { return }
        let text = "Heads up: " + lines.joined(separator: ", and ") + "."
        status.lastNudge = text
        JarvisLog.info("Nudge: \(text)")
        deliver(text, [])
    }

    private func maybeBatteryWarning() {
        guard let warnAt = modes.current.lowBatteryWarnPercent else { return }
        let b = SystemInfo.battery()
        guard b.onBattery, let pct = b.percent, pct <= warnAt, Date().timeIntervalSince(lastBatteryWarn) > 30 * 60, suppression() == nil else { return }
        lastBatteryWarn = Date()
        deliver("Battery's at \(pct) percent. Plug in when you can.", [])
    }

    private func trackCoding() {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let coding = Self.codingApps.contains { $0.caseInsensitiveCompare(front) == .orderedSame }
        let idle = PresenceDetector.idleSeconds()
        if coding && idle < 300 {
            if codingSince == nil { codingSince = Date() }
        } else if idle >= 300 || !coding {
            if !coding || idle >= 600 { codingSince = nil }
        }
        status.codingMinutes = codingSince.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
    }

    private func maybeBreakReminder() {
        let p = config.profile.proactive
        guard p.breakReminders, status.codingMinutes >= p.breakAfterMinutes,
              Date().timeIntervalSince(lastBreakNudge) > TimeInterval(p.breakAfterMinutes * 60), suppression() == nil else { return }
        lastBreakNudge = Date()
        deliver("You've been coding for \(status.codingMinutes) minutes. Worth a stretch?", [])
    }
}
