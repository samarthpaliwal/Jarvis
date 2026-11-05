import Foundation

/// Scripted moments. "homecoming": full-screen HUD, a welcome line, Home mode, then the briefing.
@MainActor
public final class SceneDirector {
    private let conversation: ConversationController
    private let hud: HUDWindowController
    private let briefing: BriefingService
    private let modes: ModeManager
    private let config: ConfigStore
    private var lastHomecoming = Date.distantPast

    public init(conversation: ConversationController, hud: HUDWindowController, briefing: BriefingService, modes: ModeManager, config: ConfigStore) {
        self.conversation = conversation; self.hud = hud; self.briefing = briefing; self.modes = modes; self.config = config
    }

    public func run(_ scene: String, trigger: String) {
        switch scene {
        case "homecoming": _ = homecoming(trigger: trigger)
        default: JarvisLog.warn("Unknown scene \(scene)")
        }
    }

    /// Welcome home: HUD up, a line in character, Home mode, the day's status. False if debounced.
    @discardableResult
    public func homecoming(trigger: String) -> Bool {
        guard Date().timeIntervalSince(lastHomecoming) > 120 else { return false }
        lastHomecoming = Date()
        JarvisLog.info("Scene: homecoming (\(trigger))")
        let name = config.profile.assistant.addressUserAs
        let snap = SystemInfo.snapshot()
        let left = ["TIME     \(Self.clock())", "POWER    \(snap.batteryPercent.map { "\($0)%" } ?? "AC") \(snap.charging ? "charging" : "")",
                    "MEMORY   \(snap.memoryPressure.uppercased())", "DISK     \(snap.diskFreeGB) GB free", "MODE     HOME"]
        hud.readouts = HUDReadouts(title: "WELCOME HOME", left: left, rightTitle: "TODAY", right: ["loading…"])
        if config.profile.hud?.fullScreenForScenes ?? true { hud.show(scene: true) }
        modes.switchTo(id: "home", reason: "homecoming")
        conversation.stopEverything()
        Task { [weak self] in
            guard let self else { return }
            let r = await self.briefing.build(mode: self.modes.current)
            self.hud.readouts = HUDReadouts(
                title: "WELCOME HOME", left: left, rightTitle: "TODAY",
                right: r.data.tasks.prefix(4).map { "• \($0.title)" } + r.data.exams.prefix(2).map { "◆ \($0.title) · \($0.daysLeft ?? 0)d" })
            let hour = Calendar.current.component(.hour, from: Date())
            let greeting = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
            let openers = ["\(greeting), \(name). Welcome home. Systems are up and the house is yours.",
                           "Welcome back, sir. Everything's where you left it.",
                           "\(greeting), \(name). Good to have you home."]
            let status = r.data.tasks.isEmpty ? "Nothing pending today." : "\(r.data.tasks.count) item\(r.data.tasks.count == 1 ? "" : "s") on the board today."
            let exam = r.data.exams.first.flatMap { e in e.daysLeft.map { "\(e.title) in \($0) day\($0 == 1 ? "" : "s")." } } ?? ""
            self.conversation.deliver([openers.randomElement()!, status, exam].filter { !$0.isEmpty }.joined(separator: " "),
                                      cards: [.briefing(r.data)]) { [weak self] in
                self?.hud.sceneEnded()
            }
        }
        return true
    }

    static func clock() -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: Date()) }
}
