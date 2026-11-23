import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from going to sleep on its own while it is plugged in, so Jarvis can still be reached
/// from the phone when nobody is at the keyboard. It is a request this app holds, like `caffeinate`: no
/// system setting is changed, the display may still sleep, and it ends when Jarvis quits or the charger
/// is unplugged. Closing the lid still sleeps the Mac.
@MainActor
public final class StayAwake {
    public static let shared = StayAwake()
    public static let key = "jarvis.stayAwakePluggedIn"

    public var enabled: Bool = UserDefaults.standard.bool(forKey: StayAwake.key) {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.key); refresh() }
    }
    public private(set) var isHolding = false
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?
    var onBattery: () -> Bool = { SystemInfo.battery().onBattery }

    nonisolated public static func shouldHold(enabled: Bool, onBattery: Bool) -> Bool { enabled && !onBattery }

    public func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    public func stop() { timer?.invalidate(); timer = nil; release() }

    public func refresh() {
        let want = Self.shouldHold(enabled: enabled, onBattery: onBattery())
        if want, !isHolding {
            let ok = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Jarvis: reachable while plugged in" as CFString, &assertion)
            isHolding = ok == kIOReturnSuccess
            JarvisLog.info(isHolding ? "Stay awake: on (plugged in)" : "Stay awake: macOS refused (\(ok))")
        } else if !want, isHolding {
            release()
            JarvisLog.info("Stay awake: off (\(enabled ? "on battery" : "switched off"))")
        }
    }

    private func release() {
        guard isHolding else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0; isHolding = false
    }
}
