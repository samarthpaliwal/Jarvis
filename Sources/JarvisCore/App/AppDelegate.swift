import AppKit

/// Boots every subsystem. Later milestones add wake word, speech, brain, and tools here.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public private(set) var config: ConfigStore!
    public private(set) var notch: NotchViewModel!
    public private(set) var notchWindow: NotchWindowController!
    public private(set) var modes: ModeManager!
    public private(set) var menuBar: MenuBarController!
    public private(set) var demo: DemoDriver!
    public private(set) var wake: WakeWordService!
    public private(set) var conversation: ConversationController!
    public private(set) var transcriber: Transcriber!
    public private(set) var speech: AppleSpeechOutput!
    public private(set) var brain: Brain!
    public private(set) var dispatcher: ToolDispatcher!
    public private(set) var undo: UndoStack!
    public private(set) var timers: TimerService!
    public private(set) var actionLog: ActionLog!
    public private(set) var calendar: CalendarService!
    public private(set) var notion: NotionClient!
    public private(set) var googleAuth: GoogleAuth!
    public private(set) var gmail: GmailClient!
    public private(set) var briefing: BriefingService!
    public private(set) var context: ContextDetector!
    public private(set) var modeSetup: ModeSetupApplier!
    public private(set) var proactive: ProactiveScheduler!
    public private(set) var moveLog: MoveLog!
    public private(set) var hud: HUDWindowController!
    public private(set) var spotter: PhraseSpotter!
    public private(set) var scenes: SceneDirector!
    public private(set) var memory: MemoryStore!
    public private(set) var skills: SkillLibrary!
    public private(set) var world: WorldService!
    public private(set) var narrator: BriefingNarrator!
    public private(set) var local: OllamaClient!
    private var edgeGlow: EdgeGlowWindowController?
    public private(set) var floating: FloatingWindowController?
    public private(set) var voice: SpeechRouter!
    public private(set) var spotify: SpotifySearch!
    private var debugSignals: DebugSignals?

    public override init() { super.init() }

    /// Config voice settings with the menu's engine override (UserDefaults "jarvis.voiceEngine") applied.
    public static func effectiveVoice(_ v: Profile.Voice?) -> Profile.Voice {
        var voice = v ?? Profile.Voice()
        if let override = UserDefaults.standard.string(forKey: "jarvis.voiceEngine") { voice.engine = override }
        return voice
    }

    /// Minimal main menu: LSUIElement apps have none by default, which silently breaks ⌘V in text fields.
    public static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        return main
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        JarvisLog.info("Jarvis starting (pid \(ProcessInfo.processInfo.processIdentifier))")
        if ConfigLocator.seedUserConfigIfNeeded() {
            JarvisLog.info("Seeded editable config at \(ConfigLocator.userConfigDirectory.path)")
        }
        ConfigLocator.mergeNewDefaultKeys()
        ConfigLocator.seedSkillsIfNeeded()
        config = ConfigStore()
        notch = NotchViewModel()
        notchWindow = NotchWindowController(model: notch)
        modes = ModeManager(config: config, notch: notch)
        demo = DemoDriver(notch: notch, config: config)
        let ui = config.profile.ui ?? Profile.UI()
        NotchViewModel.haloEnabled = ui.halo
        if ui.halo { edgeGlow = EdgeGlowWindowController(model: notch) }
        if ui.style != "notch" {
            notchWindow.enabled = false
            let f = FloatingWindowController(model: notch)
            f.pinnedDisplay = ui.screen
            f.position = FloatingWindowController.Position(rawValue: ui.position) ?? .bottom
            floating = f
        }
        JarvisLog.info("UI: \(ui.style) on \(ui.screen) screen, position \(ui.position), halo \(ui.halo)")
        wake = WakeWordService()
        transcriber = TranscriberFactory.make(locale: Locale(identifier: config.profile.speech?.locale ?? "en-US"))
        JarvisLog.info("Voice candidates: " + VoicePicker.candidates().prefix(4).map { "\($0.name)[\($0.identifier) r\(VoicePicker.rank($0))]" }.joined(separator: ", "))
        // A saved plain default voice ("Daniel") is upgraded once to the best installed voice (Siri neural first).
        if VoicePicker.shouldUpgrade(saved: UserDefaults.standard.string(forKey: "jarvis.voice")) {
            JarvisLog.info("Voice: upgrading saved default-quality voice to the best installed voice")
            UserDefaults.standard.removeObject(forKey: "jarvis.voice")
        }
        speech = AppleSpeechOutput(preferredVoice: UserDefaults.standard.string(forKey: "jarvis.voice") ?? config.profile.assistant.voiceIdentifier)
        voice = SpeechRouter(apple: speech)
        voice.configure(Self.effectiveVoice(config.profile.voice))
        spotify = SpotifySearch()
        // Safety layer + tools + brain
        undo = UndoStack()
        timers = TimerService()
        actionLog = ActionLog()
        dispatcher = ToolDispatcher(config: config, context: ToolContext(config: config, modes: modes, undo: undo, notch: notch), log: actionLog)
        calendar = CalendarService()
        notion = NotionClient()
        googleAuth = GoogleAuth()
        gmail = GmailClient(auth: googleAuth)
        briefing = BriefingService(calendar: calendar, notion: notion, gmail: gmail, profile: { [config] in config!.profile })
        context = ContextDetector(calendar: calendar)
        moveLog = MoveLog()
        memory = MemoryStore()
        skills = SkillLibrary()
        world = WorldService()
        local = OllamaClient(baseURL: URL(string: config.profile.local?.baseURL ?? "http://127.0.0.1:11434")!,
                             model: config.profile.local?.model ?? "qwen3.5:9b")
        dispatcher.register([
            SystemStatusTool(), OpenAppTool(), SetVolumeTool(), MusicTool(spotify: spotify), SetTimerTool(service: timers),
            FileSearchTool(), FileReadTool(), RunShellTool(), GetLocationContextTool(), SetModeTool(),
            UndoLastActionTool(), ActionsTodayTool(log: actionLog),
            GetBriefingTool(service: briefing), CalendarReadTool(calendar: calendar), CalendarCreateTool(calendar: calendar),
            SetReminderTool(calendar: calendar), EmailSearchTool(gmail: gmail), EmailReadTool(gmail: gmail), EmailDraftTool(gmail: gmail),
            NotionSearchTool(client: notion), NotionCreateNoteTool(client: notion),
            SetBrightnessTool(), SetFocusTool(), RememberPlaceTool(detector: context),
            OrganizeFolderTool(log: moveLog), AppHealthTool(), RestartAppTool(), PerformanceReportTool(), ClearCachesTool(),
            MemoryTool(store: memory), MemorySearchTool(store: memory), WeatherTool(world: world), NewsHeadlinesTool(world: world),
            UseSkillTool(library: skills),
        ])
        brain = Brain(dispatcher: dispatcher, config: config, modes: modes, undo: undo)
        brain.memory = memory
        brain.skills = skills
        brain.local = local
        narrator = BriefingNarrator(client: brain.client, config: config, world: world)
        hud = HUDWindowController(model: notch, dismissAfter: config.profile.hud?.dismissAfterSeconds ?? 8,
                                  preferredDisplay: config.profile.hud?.preferredDisplay)
        conversation = ConversationController(notch: notch, wake: wake, transcriber: transcriber,
                                              speech: voice, config: config, modes: modes, brain: brain)
        voice.isOnline = { [weak self] in self?.brain.isOnline ?? true }
        floating?.onClose = { [weak self] in self?.conversation.stopEverything() }
        dispatcher.register([SetDisplayModeTool(hud: hud), WelcomeHomeTool(run: { [weak self] in self?.scenes.homecoming(trigger: "voice") })])
        dispatcher.approvalHandler = { [weak self] request in await self?.conversation.requestApproval(request) ?? false }
        dispatcher.onSummary = { summary in JarvisLog.info("Action: \(summary)") }
        timers.onFire = { [weak self] entry in self?.conversation.deliver("Timer’s up: \(entry.label).") }

        // Automatic modes + their setup, and the proactive layer.
        modeSetup = ModeSetupApplier(dispatcher: dispatcher, undo: undo)
        modes.applySetup = { [weak self] mode in await self?.modeSetup.apply(mode) ?? "" }
        context.onChange = { [weak self] signals in
            guard let self else { return }
            let verdict = ModeScorer.best(signals, config: self.config.modes, current: self.modes.current.id)
            self.modes.autoSwitch(to: verdict)
        }
        context.start(pollMinutes: modes.current.pollingMinutes)
        proactive = ProactiveScheduler(config: config, modes: modes, notch: notch, briefing: briefing) { [weak self] text, cards in
            self?.conversation.deliver(text, cards: cards)
        }
        proactive.narrate = { [weak self] r, kind in await self?.narrator.narrate(r, kind: kind) ?? r.spoken }
        proactive.start()

        // Scenes, second wake phrase, arrival window.
        scenes = SceneDirector(conversation: conversation, hud: hud, briefing: briefing, modes: modes, config: config)
        scenes.narrate = { [weak self] r, kind in await self?.narrator.narrate(r, kind: kind) ?? r.spoken }
        Task { [weak self] in
            guard let self else { return }
            let s = await self.local.status()
            JarvisLog.info("Local model: Ollama \(s.running ? "running" : "not running"), \(self.local.model) \(s.hasModel ? "ready" : "not pulled"); memory: \(self.memory.entries(.facts).count) facts, \(self.memory.entries(.profile).count) profile, \(self.memory.count()) indexed; skills: \(self.skills.all.map(\.name))")
        }
        let spotTranscriber = TranscriberFactory.make(locale: Locale(identifier: config.profile.speech?.locale ?? "en-US"))
        spotter = PhraseSpotter(transcriber: spotTranscriber, phrases: config.profile.wake?.phrases ?? [])
        spotter.onHit = { [weak self] hit in self?.scenes.run(hit.scene, trigger: "phrase “\(hit.phrase)”") }
        conversation.extraAudioTap = { [weak self] chunk in self?.spotter.append(chunk) }
        conversation.onTurnActive = { [weak self] active in
            if active { self?.spotter.pause() } else { self?.spotter.resumeIfWindowOpen() }
        }
        conversation.homecomingIfArriving = { [weak self] in
            guard let self, self.config.profile.wake?.homecomingOnHeyJarvis ?? true,
                  let until = self.spotter.activeUntil, until > Date() else { return false }
            guard self.scenes.homecoming(trigger: "Hey Jarvis during arrival window") else { return false }
            self.spotter.stop(reason: "homecoming via Hey Jarvis")
            return true
        }
        context.homePlaces = { [weak self] in self?.config.modes.places.filter { $0.id == "home" } ?? [] }
        context.onArrivedHome = { [weak self] why in
            guard let self else { return }
            self.spotter.openWindow(minutes: self.config.profile.wake?.arrivalWindowMinutes ?? 10, reason: why)
        }
        if config.profile.wake?.alwaysSpotPhrases ?? false { spotter.start() }
        Task { _ = await spotTranscriber.requestAuthorization() }
        menuBar = MenuBarController(config: config, notch: notch, notchWindow: notchWindow, modes: modes,
                                    demo: demo, wake: wake, conversation: conversation, speech: speech, voice: voice, spotify: spotify, brain: brain, log: actionLog,
                                    googleAuth: googleAuth, notion: notion, briefing: briefing,
                                    proactive: proactive, context: context, hud: hud, scenes: scenes,
                                    memory: memory, skills: skills, local: local, narrator: narrator)
        JarvisLog.info("Brain: model \(brain.model), \(dispatcher.tools.count) tools, API key \(KeychainStore.apiKey() == nil ? "MISSING" : "present")")
        debugSignals = DebugSignals(onWake: { [weak self] in self?.wake.simulateWake() },
                                    onBriefing: { [weak self] in
                                        guard let self else { return }
                                        Task {
                                            let r = await self.briefing.build(mode: self.modes.current)
                                            JarvisLog.info("Briefing: tasks=\(r.data.tasks.count) deadlines=\(r.data.deadlines.count) exams=\(r.data.exams.count) notes=\(r.notes)")
                                            self.conversation.deliver(r.spoken, cards: [.briefing(r.data)])
                                        }
                                    },
                                    onApprovalDemo: { [weak self] in
                                        guard let self else { return }
                                        // If ~/Library/Application Support/Jarvis/ask.txt exists, run its text as a turn instead.
                                        let askURL = ConfigLocator.userConfigDirectory.deletingLastPathComponent().appendingPathComponent("ask.txt")
                                        if let q = try? String(contentsOf: askURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
                                            try? FileManager.default.removeItem(at: askURL)
                                            if q == "!homecoming" { self.scenes.homecoming(trigger: "debug"); return }
                                            if q == "!arrive" { self.spotter.openWindow(minutes: 10, reason: "debug"); return }
                                            if q == "!hud" { self.hud.show(scene: false); return }
                                            if q == "!brief" {
                                                Task { let r = await self.briefing.build(mode: self.modes.current); self.conversation.deliver(await self.narrator.narrate(r, kind: "briefing on request"), cards: [.briefing(r.data)]) }
                                                return
                                            }
                                            JarvisLog.info("Text turn: “\(q)”")
                                            self.conversation.ask(q)
                                            return
                                        }
                                        Task {
                                            let r = await self.dispatcher.call("run_shell", input: ["command": "echo hello from Jarvis && date", "why": "approval demo"], source: .user)
                                            self.conversation.deliver(r.isError ? r.content : "Ran it. Output: \(r.content.suffix(60))")
                                        }
                                    }, demo: demo)
        JarvisLog.info("Speech in: \(transcriber.name) · Speech out: \(voice.engineName) · Apple fallback: \(speech.name)")

        // JARVIS_NO_WAKE=1 skips the microphone entirely (used for CPU baselines).
        if ProcessInfo.processInfo.environment["JARVIS_NO_WAKE"] != "1" {
            Task {
                await wake.start()
                let ok = await transcriber.requestAuthorization()
                JarvisLog.info("Speech recognition permission: \(ok ? "granted" : "not granted")")
            }
        }

        let g = notchWindow.geometry
        JarvisLog.info("Notch detected=\(g.hasNotch) width=\(Int(g.notchWidth)) height=\(Int(g.notchHeight)) reduceMotion=\(notch.reduceMotion)")
    }

    public func applicationWillTerminate(_ notification: Notification) {
        wake?.stop()
        JarvisLog.info("Jarvis quitting")
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
