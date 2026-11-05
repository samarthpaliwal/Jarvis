import AppKit
import Foundation

/// Applies a mode's `setup` block through the dispatcher (source `.mode`, so Tier 2 is impossible)
/// and remembers the previous state so leaving the mode, or "undo that", restores it.
@MainActor
public final class ModeSetupApplier {
    private struct Snapshot {
        var modeID: String
        var volume: Float
        var muted: Bool
        var brightness: Float?
        var hidden: [String]
        var quit: [URL]
        var focusWasSet: String?
    }

    private let dispatcher: ToolDispatcher
    private let undo: UndoStack
    private var snapshot: Snapshot?

    public init(dispatcher: ToolDispatcher, undo: UndoStack) {
        self.dispatcher = dispatcher
        self.undo = undo
    }

    /// Runs the setup for `mode`. Returns a one-line summary of what changed.
    public func apply(_ mode: ModeDefinition) async -> String {
        await restorePrevious() // leaving the old mode first
        let setup = mode.setup
        var done: [String] = []
        var snap = Snapshot(modeID: mode.id, volume: AudioOutput.volume(), muted: AudioOutput.isMuted(),
                            brightness: Brightness.current(), hidden: [], quit: [], focusWasSet: nil)

        if let v = setup.volume {
            let r = await dispatcher.call("set_volume", input: ["percent": Int(v * 100)], source: .mode)
            if !r.isError { done.append("volume \(Int(v * 100))%") }
        }
        if let b = setup.brightness {
            let r = await dispatcher.call("set_brightness", input: ["percent": Int(b * 100)], source: .mode)
            if !r.isError { done.append("brightness \(Int(b * 100))%") }
        }
        for app in setup.quitApps {
            if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.caseInsensitiveCompare(app) == .orderedSame }),
               let url = running.bundleURL {
                let r = await dispatcher.call("open_app", input: ["name": app, "action": "quit"], source: .mode)
                if !r.isError { snap.quit.append(url); done.append("quit \(app)") }
            }
        }
        for app in setup.hideApps {
            let r = await dispatcher.call("open_app", input: ["name": app, "action": "hide"], source: .mode)
            if !r.isError, !r.content.contains("not running") { snap.hidden.append(app); done.append("hid \(app)") }
        }
        for app in setup.openApps {
            let r = await dispatcher.call("open_app", input: ["name": app], source: .mode)
            if !r.isError { done.append("opened \(app)") }
        }
        if let focus = setup.focus ?? (setup.muteNotifications ? "Do Not Disturb" : nil) {
            let r = await dispatcher.call("set_focus", input: ["focus": focus], source: .mode)
            if !r.isError { snap.focusWasSet = focus; done.append("focus \(focus)") }
        }
        snapshot = snap
        if !done.isEmpty {
            let id = mode.id
            undo.push(.init(description: "\(mode.name) mode setup") { [weak self] in
                await self?.restorePrevious(ifMode: id)
                return "Restored what \(mode.name) mode changed."
            })
        }
        return done.isEmpty ? "" : done.joined(separator: ", ")
    }

    /// Undo everything the last setup did (volume, brightness, hidden/quit apps, focus).
    public func restorePrevious(ifMode: String? = nil) async {
        guard let s = snapshot, ifMode == nil || ifMode == s.modeID else { return }
        snapshot = nil
        try? AudioOutput.setVolume(s.volume)
        try? AudioOutput.setMuted(s.muted)
        if let b = s.brightness { Brightness.set(b) }
        for app in s.hidden {
            NSWorkspace.shared.runningApplications.first { $0.localizedName?.caseInsensitiveCompare(app) == .orderedSame }?.unhide()
        }
        for url in s.quit {
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        if s.focusWasSet != nil {
            _ = await dispatcher.call("set_focus", input: ["focus": "off"], source: .mode)
        }
        JarvisLog.info("Mode setup restored (\(s.modeID))")
    }
}

/// Display brightness via the private DisplayServices framework (no public API exists).
/// Fails quietly on displays that don't support it (most external monitors).
public enum Brightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    public static func current() -> Float? {
        guard let h = handle, let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        let fn = unsafeBitCast(sym, to: GetFn.self)
        var v: Float = 0
        return fn(CGMainDisplayID(), &v) == 0 ? v : nil
    }

    @discardableResult
    public static func set(_ value: Float) -> Bool {
        guard let h = handle, let sym = dlsym(h, "DisplayServicesSetBrightness") else { return false }
        let fn = unsafeBitCast(sym, to: SetFn.self)
        return fn(CGMainDisplayID(), max(0, min(1, value))) == 0
    }
}
