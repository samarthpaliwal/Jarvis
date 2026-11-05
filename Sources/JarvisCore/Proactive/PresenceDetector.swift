import AppKit
import CoreMediaIO
import Foundation

/// "Is Sam in a call or sharing the screen?" Any camera in use by another process, or a call app
/// running, means Jarvis stays silent. Read-only, no permissions.
public enum PresenceDetector {
    public static let defaultCallApps = ["zoom.us", "FaceTime", "Microsoft Teams", "Webex", "Google Meet", "Slack Huddle", "Discord"]

    public static func isInCallOrSharing(callApps: [String]) -> Bool {
        if cameraInUse() { return true }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
        let callers = callApps.filter { app in running.contains { $0.caseInsensitiveCompare(app) == .orderedSame } }
        // Discord/Slack are often open without a call; only count them when frontmost.
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        return callers.contains { !["Discord", "Slack Huddle"].contains($0) || $0.caseInsensitiveCompare(front) == .orderedSame }
    }

    /// True if any video capture device reports "running somewhere".
    public static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == noErr else { return false }
        for dev in devices {
            var running: UInt32 = 0
            let rsize = UInt32(MemoryLayout<UInt32>.size)
            var raddr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(dev, &raddr, 0, nil, rsize, &got, &running) == noErr, running != 0 { return true }
        }
        return false
    }

    /// Seconds since the last keyboard/mouse event (for break reminders and "is he even here").
    public static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: ~0)!)
    }
}
