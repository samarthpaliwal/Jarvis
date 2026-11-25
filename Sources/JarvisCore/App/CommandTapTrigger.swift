import CoreGraphics
import Foundation

/// Recognises "Command tapped N times quickly, with nothing else pressed" from a stream of samples.
/// No system calls in here, so the rules are tested.
///
/// A tap is: Command goes down and comes back up within `maxHold`, no other modifier was held, and no key
/// or mouse button was pressed in between. That last check is what stops Cmd+C, Cmd+V and Cmd-click from
/// counting. Each next tap must start within `maxGap` of the last one ending, again with nothing pressed.
public struct CommandTapDetector: Equatable, Sendable {
    public struct Settings: Equatable, Sendable {
        /// How many taps fire the action.
        public var taps = 3
        public var maxHold: TimeInterval = 0.26
        public var maxGap: TimeInterval = 0.38
        public init(taps: Int = 3, maxHold: TimeInterval = 0.26, maxGap: TimeInterval = 0.38) {
            self.taps = max(2, min(5, taps)); self.maxHold = maxHold; self.maxGap = maxGap
        }
    }
    public var settings: Settings

    private var down = false
    private var downAt: TimeInterval = 0
    private var pressesAtDown: UInt64 = 0
    private var spoiled = false
    /// Clean taps so far in this run, and when and where the last one ended.
    private var count = 0
    private var lastUpAt: TimeInterval = 0
    private var pressesAtLastUp: UInt64 = 0

    public init(settings: Settings = Settings()) { self.settings = settings }

    /// One look at the keyboard. `presses` is a running total of key and mouse-button presses.
    /// Returns true on the sample that completes the run of taps.
    public mutating func sample(command: Bool, otherModifier: Bool, presses: UInt64, at t: TimeInterval) -> Bool {
        if command, !down {
            down = true; downAt = t; pressesAtDown = presses; spoiled = otherModifier
            // Too slow, or something was pressed since the last tap: this one starts a new run.
            if count > 0, t - lastUpAt > settings.maxGap || presses != pressesAtLastUp { count = 0 }
        } else if command, down {
            if otherModifier { spoiled = true }
        } else if !command, down {
            down = false
            let clean = !spoiled && t - downAt <= settings.maxHold && presses == pressesAtDown
            guard clean else { count = 0; return false }
            count += 1
            if count >= settings.taps { count = 0; return true }
            lastUpAt = t; pressesAtLastUp = presses
        }
        return false
    }
}

/// Fires an action when Command is tapped three times (by default) from anywhere in macOS.
///
/// It needs no Accessibility or Input Monitoring permission because it never sees which keys are typed:
/// about 80 times a second it asks macOS two things, "is Command down right now" and "how many key and
/// mouse presses have there been so far", and nothing else.
public final class CommandTapTrigger: @unchecked Sendable {
    public static let interval: TimeInterval = 0.012
    private let queue = DispatchQueue(label: "com.samarth.jarvis.commandtap", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var detector: CommandTapDetector
    private let onFire: @Sendable () -> Void
    private let lock = NSLock()

    public init(settings: CommandTapDetector.Settings = .init(), onFire: @escaping @Sendable () -> Void) {
        detector = CommandTapDetector(settings: settings)
        self.onFire = onFire
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return timer != nil }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let state = CGEventSourceStateID.combinedSessionState
        let flags = CGEventSource.flagsState(state)
        let presses = UInt64(CGEventSource.counterForEventType(state, eventType: .keyDown))
            + UInt64(CGEventSource.counterForEventType(state, eventType: .leftMouseDown))
            + UInt64(CGEventSource.counterForEventType(state, eventType: .rightMouseDown))
        let other = !flags.intersection([.maskShift, .maskControl, .maskAlternate]).isEmpty
        if detector.sample(command: flags.contains(.maskCommand), otherModifier: other, presses: presses,
                           at: ProcessInfo.processInfo.systemUptime) {
            onFire()
        }
    }
}
