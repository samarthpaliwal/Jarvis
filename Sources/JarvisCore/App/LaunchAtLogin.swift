import Foundation
import ServiceManagement

/// Wraps SMAppService. Only works when running from a real .app bundle.
public enum LaunchAtLogin {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    @discardableResult
    public static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            JarvisLog.info("Launch at login \(enabled ? "enabled" : "disabled")")
            return true
        } catch {
            JarvisLog.error("Launch at login change failed: \(error.localizedDescription)")
            return false
        }
    }
}
