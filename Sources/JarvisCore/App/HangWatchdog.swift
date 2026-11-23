import Foundation

/// Notices when the main thread has stopped responding and restarts Jarvis.
///
/// The launchd supervisor restarts Jarvis after a crash, but a frozen app has not crashed: it sits there
/// deaf and unresponsive. A background timer pings the main thread; if the pings stop coming back for
/// `timeout` seconds, Jarvis logs why and exits with an error code, and launchd starts a fresh copy.
/// Time is measured on a clock that does not run while the Mac sleeps.
public final class HangWatchdog: @unchecked Sendable {
    public var timeout: TimeInterval
    public var interval: TimeInterval
    /// What to do when the main thread is stuck. Default: exit, so the supervisor restarts Jarvis.
    public var onHang: (TimeInterval) -> Void

    private let uptime: () -> TimeInterval
    private let queue = DispatchQueue(label: "com.samarth.jarvis.hangwatchdog", qos: .utility)
    private let lock = NSLock()
    private var lastPong: TimeInterval
    private var timer: DispatchSourceTimer?
    private var fired = false

    public init(timeout: TimeInterval = 30, interval: TimeInterval = 5,
                uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                onHang: @escaping (TimeInterval) -> Void) {
        self.timeout = timeout; self.interval = interval; self.uptime = uptime; self.onHang = onHang
        lastPong = uptime()
    }

    public func start() {
        guard timeout > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() { timer?.cancel(); timer = nil }

    /// The main thread answered.
    public func pong() { lock.lock(); lastPong = uptime(); lock.unlock() }

    /// One check. Returns how long the main thread has been silent. Called on the watchdog queue; public for tests.
    @discardableResult
    public func tick() -> TimeInterval {
        lock.lock()
        let silent = uptime() - lastPong
        let shouldFire = silent >= timeout && !fired
        if shouldFire { fired = true }
        lock.unlock()
        if shouldFire { onHang(silent) }
        // Ask the run loop, not the main dispatch queue: a modal dialog opened from a main-queue block stalls
        // that queue while the app is perfectly alive (this restarted Jarvis mid-pairing on 2026-11-23).
        RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.pong() }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        return silent
    }
}
