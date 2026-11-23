import Foundation

/// What the phone is shown for an open question.
public struct CheckInView: Equatable, Sendable {
    public var id: String
    public var text: String
    public var modes: [[String]]        // [id, name]
    public var current: String
}

/// When the phone radar sees Sam leave or come back, ask him on the phone which mode the Mac should be in
/// and whether anyone is there. The answer changes the mode and Do Not Disturb, nothing else: a mode
/// change can never start an action that needs approval.
@MainActor
public final class PresenceCheckIns {
    private var box = CheckInBox()
    private let push: PushStore
    private let modes: ModeManager
    private let notch: NotchViewModel
    private let now: () -> Date
    /// Whether Sam last said other people are around. While true, Jarvis does not speak up by itself.
    public private(set) var peoplePresent = false

    public init(push: PushStore, modes: ModeManager, notch: NotchViewModel, now: @escaping () -> Date = Date.init) {
        self.push = push; self.modes = modes; self.notch = notch; self.now = now
    }

    public var pushStore: PushStore { push }

    /// Called by the radar. The first reading after launch is not a change.
    public func phoneChanged(to state: PresenceTracker.State, from previous: PresenceTracker.State) {
        let kind: CheckIn.Kind
        switch (previous, state) {
        case (.near, .away): kind = .left
        case (.away, .near): kind = .back
        default: return
        }
        guard let q = box.ask(kind, at: now()) else { return }
        JarvisLog.info("Check-in: asking the phone (\(kind.rawValue))")
        Task {
            let sent = await push.notify(title: "Jarvis", body: q.text, tag: "check-in")
            JarvisLog.info(sent > 0 ? "Check-in: notification sent to \(sent) phone(s)" : "Check-in: no phone has notifications on; the question waits in the phone app")
        }
    }

    public func current() -> CheckInView? {
        guard let q = box.current(at: now()) else { return nil }
        return CheckInView(id: q.id.uuidString, text: q.text, modes: modes.available.map { [$0.id, $0.name] }, current: modes.current.id)
    }

    /// Applies an answer. Nil when the question is no longer open.
    public func answer(id: UUID, mode: String?, people: Bool?) -> String? {
        if let mode, !modes.available.contains(where: { $0.id == mode }) { return nil }
        guard box.answer(id, at: now()) else { return nil }
        var said: [String] = []
        if let mode, mode != modes.current.id {
            modes.switchTo(id: mode, reason: "phone check-in")
            said.append("\(modes.current.name) mode")
        } else if mode != nil { said.append("staying in \(modes.current.name) mode") }
        if let people {
            peoplePresent = people
            notch.doNotDisturb = people
            UserDefaults.standard.set(people, forKey: "jarvis.doNotDisturb")
            said.append(people ? "people are there, so I'll stay quiet" : "nobody else there")
        }
        JarvisLog.info("Check-in answered: \(said.joined(separator: "; "))")
        return said.isEmpty ? "Noted." : "Got it: " + said.joined(separator: ", ") + "."
    }
}
