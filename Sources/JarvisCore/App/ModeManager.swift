import Foundation
import Combine

/// Tracks the active context mode (Home / Class / Study / Work / Road).
/// Milestone 1: manual switching only. Automatic detection (location, Wi-Fi, power, displays)
/// and the per-mode setup actions arrive in Milestone 6.
@MainActor
public final class ModeManager: ObservableObject {
    @Published public private(set) var current: ModeDefinition
    /// Set when the user picked a mode by hand; automatic detection waits until it expires.
    @Published public private(set) var manualUntil: Date?
    @Published public private(set) var lastAutoReason: String?
    /// Runs the mode's setup block; returns a one-line summary. Wired by the app.
    public var applySetup: ((ModeDefinition) async -> String)?
    private let config: ConfigStore
    private let notch: NotchViewModel
    private let defaultsKey = "jarvis.currentMode"

    public init(config: ConfigStore, notch: NotchViewModel) {
        self.config = config
        self.notch = notch
        let savedID = UserDefaults.standard.string(forKey: defaultsKey)
        let initial = savedID.flatMap { config.modes.mode(id: $0) }
            ?? config.modes.mode(id: config.modes.defaultMode)
            ?? config.modes.modes.first
            ?? ModesConfig.fallback.modes[0]
        current = initial
        apply(initial, announce: false)
    }

    public var available: [ModeDefinition] { config.modes.modes }

    /// Switch modes. `reason` is logged ("menu", "voice", "auto: at campus", ...).
    public func switchTo(id: String, reason: String) {
        guard let mode = config.modes.mode(id: id) else {
            JarvisLog.warn("Unknown mode '\(id)' requested via \(reason)")
            return
        }
        let manual = !reason.hasPrefix("auto")
        if manual { manualUntil = Date().addingTimeInterval(config.profile.proactive.manualOverrideHours * 3600) }
        guard mode.id != current.id else { return }
        JarvisLog.info("Mode \(current.id) -> \(mode.id) (\(reason))")
        current = mode
        UserDefaults.standard.set(mode.id, forKey: defaultsKey)
        apply(mode, announce: true)
        if let applySetup {
            Task { [weak self] in
                let summary = await applySetup(mode)
                if !summary.isEmpty, mode.id != "class" { self?.notch.flash("\(mode.name) mode: \(summary)", seconds: 5) }
            }
        }
    }

    /// Called by the context detector. Respects the manual override window.
    public func autoSwitch(to verdict: ModeScorer.Verdict?) {
        guard config.profile.proactive.autoModes else { return }
        if let until = manualUntil, until > Date() { return }
        manualUntil = nil
        guard let v = verdict else { return }
        lastAutoReason = "\(v.modeID): \(v.reasons.joined(separator: ", "))"
        switchTo(id: v.modeID, reason: "auto: \(v.reasons.joined(separator: ", "))")
    }

    public func clearManualOverride() { manualUntil = nil }

    private func apply(_ mode: ModeDefinition, announce: Bool) {
        notch.modeIcon = mode.icon
        notch.modeName = mode.name
        notch.glowStrength = mode.notch.glow
        // Class mode is quiet: no confirmation at all.
        if announce && mode.id != "class" {
            notch.flash("\(mode.name) mode", seconds: 2.5)
        }
    }
}
