import AppKit
import Combine

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
    private var restartedAfterCrash = false
    public private(set) var remote: RemoteAccess!
    private var retentionTimer: Timer?

    /// Where data goes with the current settings (menu → Privacy, and the startup log).
    public func dataFlows() -> [DataFlow] {
        let listening: Bool = { if case .listening = remote?.state { return true } else { return false } }()
        return Privacy.flows(PrivacySnapshot(
            transcriber: transcriber.name, transcriberUsesServer: transcriber.sendsAudioOffDevice, voiceEngine: voice.engineKind,
            claudeConfigured: KeychainStore.apiKey() != nil || SecretVault.shared.state == .locked || SecretVault.shared.state == .unlocking,
            hostedModel: (brain?.hosted?.hasKey ?? false) && !(brain?.privateMode ?? false) ? brain?.hosted?.model : nil,
            privateMode: brain?.privateMode ?? false,
            googleConnected: KeychainStore.read(account: GoogleAuth.refreshTokenAccount) != nil,
            notionConnected: KeychainStore.read(account: NotionClient.tokenAccount) != nil,
            spotifyConnected: KeychainStore.read(account: SpotifySearch.clientIDAccount) != nil,
            goveeConnected: KeychainStore.read(account: GoveeClient.keyAccount) != nil,
            computerControlOn: computerControl.isEnabled,
            notificationsOn: !(checkIns?.pushStore.devices.isEmpty ?? true),
            remoteListening: listening, voiceIDEnrolled: voiceID?.isEnrolled ?? false))
    }
    /// This very process was started by the launchd agent.
    private var supervisedByLaunchd = false
    private var unlockingKeys = false
    /// What the Keys menu shows. Updated after each unlock; reading it never spawns the helper.
    public private(set) var keyStatus: (vault: [String], legacy: [String], touchID: Bool)?
    private var hangWatchdog: HangWatchdog!
    public private(set) var budget: Budget!
    public private(set) var contacts: ContactBook!
    public private(set) var frames: FrameSources!
    public private(set) var camera: CameraController!
    public private(set) var voiceID: SpeakerVerifier!
    public private(set) var faceWatcher: FaceWatcher!
    public private(set) var faceStore: FaceTemplateStore!
    public private(set) var ownerLock: OwnerLock!
    public private(set) var devices: DeviceHub!
    private var faceEnrollmentPending = false
    private var enrollmentPending = false
    public private(set) var glasses: PushedFrameSource!
    private var termSource: DispatchSourceSignal?
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
    public let computerControl = ComputerControl()
    public let radar = PhoneRadar()
    public private(set) var checkIns: PresenceCheckIns?
    private var controlWatcher: ControlInterruptWatcher?
    private var controlTimer: Timer?
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
    public private(set) var kokoro: KokoroService!
    private var cancellables: Set<AnyCancellable> = []
    private var debugSignals: DebugSignals?

    public override init() { super.init() }

    /// Config voice settings with the menu's engine override (UserDefaults "jarvis.voiceEngine") applied.
    public static func effectiveVoice(_ v: Profile.Voice?) -> Profile.Voice {
        var voice = v ?? Profile.Voice()
        if let override = UserDefaults.standard.string(forKey: "jarvis.voiceEngine") { voice.engine = override }
        if let k = UserDefaults.standard.string(forKey: "jarvis.kokoroVoice") { voice.kokoroVoice = k }
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
        let me = ProcessInfo.processInfo.processIdentifier
        let agent = Supervisor.agentState
        supervisedByLaunchd = agent.pid == me
        JarvisLog.info("Jarvis starting (pid \(me)\(supervisedByLaunchd ? ", supervised by launchd" : agent.loaded ? ", opened by hand" : ""))")
        // The login item and the launchd agent can both start a copy. The second one leaves quietly;
        // exit code 0 tells launchd not to restart it.
        if Supervisor.anotherInstanceIsRunning {
            JarvisLog.warn("Another Jarvis is already running; this copy is exiting")
            exit(0)
        }
        // Opened by hand while the supervisor is idle (after Quit, say): let launchd run it instead, so it
        // is restarted after a crash and replaced cleanly on a rebuild.
        if Supervisor.shouldHandOver(agent: agent, myProgram: Bundle.main.executablePath ?? CommandLine.arguments[0]) {
            JarvisLog.info("Handing over to the launchd supervisor; it starts Jarvis in a second")
            Supervisor.startAgentSoon()
            exit(0)
        }
        let launch = Supervisor.noteLaunch()
        if launch.crashLooping {
            // Exit cleanly so launchd stops restarting a build that cannot start.
            JarvisLog.error("Jarvis started more than 5 times in 2 minutes. Stopping so launchd does not keep restarting it. Check launchd.err.log and the crash reports, then start Jarvis by hand.")
            Supervisor.noteCleanExit()
            exit(0)
        }
        restartedAfterCrash = launch.afterUncleanExit
        // `kill` (SIGTERM) is a request to quit: quit cleanly, so the supervisor does not bring Jarvis back.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { JarvisLog.info("SIGTERM received; quitting cleanly"); NSApp.terminate(nil) }
        term.resume()
        termSource = term
        if ConfigLocator.seedUserConfigIfNeeded() {
            JarvisLog.info("Seeded editable config at \(ConfigLocator.userConfigDirectory.path)")
        }
        ConfigLocator.mergeNewDefaultKeys()
        ConfigLocator.seedSkillsIfNeeded()
        config = ConfigStore()
        // Saved keys: one unlock through the key helper (Touch ID), then everything is read from memory.
        // Without the helper installed this is the old direct Keychain path, now cached.
        SecretVault.shared.configure(helper: ProcessKeyHelper())
        JarvisLog.info("Keys: " + (SecretVault.shared.usesHelper ? "key helper installed; unlocking" : "key helper not installed (scripts/install-keyhelper.sh); reading the Keychain directly"))
        unlockKeys()
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
        FileLog.maxBytes = Int(config.tuning.logMaxMegabytes * 1024 * 1024)
        FileLog.keepFiles = config.tuning.logKeepFiles
        AppleSpeechTranscriber.allowServer = config.tuning.cloudSpeechRecognition.lowercased() == "allow"
        // Data retention: drop what is older than the policy allows, now and once a day.
        let retention = Retention.Policy(config.tuning)
        let sweep: @Sendable () -> Void = {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let r = Retention.sweep(retention, media: [home.appendingPathComponent("Movies/Jarvis"), home.appendingPathComponent("Pictures/Jarvis")])
            if !r.isEmpty { JarvisLog.info("Retention: removed \(r.linesRemoved) old log lines and \(r.filesRemoved) old log files; moved \(r.mediaTrashed) old recordings to the Trash") }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { sweep() }
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in DispatchQueue.global(qos: .utility).async { sweep() } }
        HTTP.policy = config.tuning.retryPolicy
        StayAwake.shared.start()
        wake = WakeWordService()
        wake.tuning = config.tuning
        transcriber = TranscriberFactory.make(locale: Locale(identifier: config.profile.speech?.locale ?? "en-US"))
        JarvisLog.info("Voice candidates: " + VoicePicker.candidates().prefix(4).map { "\($0.name)[\($0.identifier) r\(VoicePicker.rank($0))]" }.joined(separator: ", "))
        // A saved plain default voice ("Daniel") is upgraded once to the best installed voice (Siri neural first).
        if VoicePicker.shouldUpgrade(saved: UserDefaults.standard.string(forKey: "jarvis.voice")) {
            JarvisLog.info("Voice: upgrading saved default-quality voice to the best installed voice")
            UserDefaults.standard.removeObject(forKey: "jarvis.voice")
        }
        speech = AppleSpeechOutput(preferredVoice: UserDefaults.standard.string(forKey: "jarvis.voice") ?? config.profile.assistant.voiceIdentifier)
        voice = SpeechRouter(apple: speech)
        kokoro = KokoroService(port: config.tuning.kokoroPort)
        CloudSpeechOutput.kokoroBaseURL = kokoro.baseURL
        CloudSpeechOutput.openAIModel = config.tuning.openaiTtsModel
        CloudSpeechOutput.requestTimeout = config.tuning.ttsRequestTimeoutSeconds
        voice.kokoroReady = { [weak self] in self?.kokoro.isReady ?? false }
        voice.configure(Self.effectiveVoice(config.profile.voice))
        kokoro.onReady = { [weak self] in
            guard let self else { return }
            self.voice.configure(Self.effectiveVoice(self.config.profile.voice))
        }
        kokoro.start()
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
        let drafts = DraftLedger()
        // Voice ID: the model is read from disk only when a voiceprint exists or setup starts.
        let embedder = LazyECAPAEmbedder()
        voiceID = SpeakerVerifier(embedder: embedder, threshold: config.tuning.speakerThreshold)
        JarvisLog.info("Voice ID: " + (!embedder.isInstalled ? "model not installed (scripts/setup-voiceid.sh)" : voiceID.isEnrolled ? "on, threshold \(config.tuning.speakerThreshold)" : "not set up"))
        contacts = ContactBook(system: MacContacts())
        // Camera now; "glasses" is the hook a bridge will push frames into (remote-access phase).
        glasses = PushedFrameSource(name: "glasses")
        camera = CameraController()
        camera.maxRecordingSeconds = { [weak self] in self?.config.tuning.videoMaxSeconds ?? 300 }
        camera.onNotice = { [weak self] text in self?.conversation?.announceWhenIdle(text) }
        frames = FrameSources([CameraFrameSource(session: camera.session), glasses], default: "camera")
        // Face recognition and the owner lock. Nothing here touches the camera until a face is enrolled
        // and the lock is on; the model is read from disk the first time it is needed.
        faceStore = FaceTemplateStore()
        let faceCamera = LiveFaceCamera(session: camera.session)
        faceCamera.framesPerSecond = min(15, max(2, config.profile.face?.framesPerSecond ?? 6))
        let faceModel = LazySFaceEmbedder()
        let store = faceStore!
        faceWatcher = FaceWatcher(camera: faceCamera, embedder: { try faceModel.get() }, template: { try store.load() })
        ownerLock = OwnerLock(watcher: faceWatcher, settings: { [config] in
            var s = config!.profile.face?.lock ?? OwnerLock.Settings()
            s.phoneRequired = config!.profile.phone?.required ?? false
            return s
        }, isEnrolled: { store.exists })
        // The second check: is the chosen phone near (Bluetooth, listen-only). Nil until a phone is chosen.
        ownerLock.phone = { [radar] in radar.phoneID == nil ? nil : radar.check }
        radar.apply((config.profile.phone ?? PhoneConfig()).tracker)
        if config.profile.phone?.required ?? false, radar.phoneID != nil, !radar.enabled { radar.enabled = true }
        dispatcher.ownerGate = { [weak self] tool, fromPhone in await self?.ownerLock.refusal(tool: tool, fromPhone: fromPhone) }
        JarvisLog.info("Owner lock: " + (!SFaceEmbedder.isInstalled ? "face model not installed (scripts/setup-faceid.sh)"
                                         : !store.exists ? "no face enrolled" : ownerLock.isActive ? "on" : "face enrolled, lock off"))
        // A page that opens under the full-screen HUD cannot be seen, so the HUD steps aside first.
        let openInBrowser: @MainActor (URL) -> Bool = { [weak self] url in
            self?.hud?.stepAside(reason: "browser")
            return NSWorkspace.shared.open(url)
        }
        dispatcher.register([
            SystemStatusTool(), OpenAppTool(), GoogleSearchTool(open: openInBrowser), OpenWebsiteTool(open: openInBrowser), LightsTool(govee: GoveeClient()), SetVolumeTool(), SpeechSpeedTool(read: { [config] in config.profile.assistant.pace }, save: { [config] in try config.save(speechSpeed: $0) }), MusicTool(spotify: spotify), SetTimerTool(service: timers),
            FileSearchTool(), FileReadTool(), RunShellTool(), GetLocationContextTool(), SetModeTool(),
            UndoLastActionTool(), ActionsTodayTool(log: actionLog),
            GetBriefingTool(service: briefing), CalendarReadTool(calendar: calendar), CalendarCreateTool(calendar: calendar),
            CalendarMoveTool(calendar: calendar), CalendarCancelTool(calendar: calendar),
            SetReminderTool(calendar: calendar), EmailSearchTool(gmail: gmail), EmailReadTool(gmail: gmail), EmailDraftTool(gmail: gmail, ledger: drafts), EmailSendTool(gmail: gmail, ledger: drafts),
            NotionSearchTool(client: notion), NotionCreateNoteTool(client: notion),
            SetBrightnessTool(), SetFocusTool(), RememberPlaceTool(detector: context),
            OrganizeFolderTool(log: moveLog), AppHealthTool(), RestartAppTool(), PerformanceReportTool(), ClearCachesTool(),
            MemoryTool(store: memory), MemorySearchTool(store: memory), WeatherTool(world: world), NewsHeadlinesTool(world: world),
            UseSkillTool(library: skills), ContactsTool(book: contacts), LookTool(sources: frames), CameraTool(camera: camera),
            OwnerLockTool(lock: ownerLock, hooks: .init(
                status: { [weak self] in self?.ownerLockStatus() ?? "The owner lock is not available." },
                isEnrolled: { store.exists }, modelInstalled: { SFaceEmbedder.isInstalled },
                startEnrollment: { [weak self] in self?.startFaceEnrollment() },
                forget: { [weak self] in try self?.forgetFace() },
                setEnabled: { [config] in try config!.save(faceLockEnabled: $0) },
                setPhoneRequired: { [weak self] on in
                    guard let self, self.radar.phoneID != nil else { throw FaceError.notEnrolled }
                    try self.config.save(phoneRequired: on)
                    if on, !self.radar.enabled { self.radar.enabled = true }
                })),
            VoiceIDTool(verifier: voiceID, lastCheck: { [weak self] in self?.conversation?.lastVoiceCheck },
                        startEnrollment: { [weak self] in self?.startVoiceEnrollment() }),
        ])
        // Every paid call goes through one spend guard: a daily cap, a per-minute rate limit, and a ledger.
        budget = Budget(limits: config.tuning.budgetLimits, pricing: config.profile.pricing ?? Pricing())
        CloudSpeechOutput.budget = budget
        budget.onNotice = { [weak self] notice in
            DispatchQueue.main.async {
                JarvisLog.warn("Budget: \(Budget.spoken(notice))")
                self?.conversation?.announceWhenIdle(Budget.spoken(notice))
            }
        }
        JarvisLog.info("Budget: \(budget.summary), warn at \(Int(config.tuning.budgetWarnFraction * 100))%, \(config.tuning.modelRequestsPerMinute) model requests/min")
        brain = Brain(client: MeteredModel(ClaudeClient(tuning: config.tuning), budget: budget), dispatcher: dispatcher, config: config, modes: modes, undo: undo)
        brain.memory = memory
        brain.skills = skills
        brain.local = local
        // The second cloud brain. It costs nothing to have ready: without a key it is simply never used.
        if let url = URL(string: config.tuning.hostedBaseURL), url.scheme == "https" {
            brain.hosted = OllamaClient.hosted(baseURL: url, model: config.tuning.hostedModel)
        }
        narrator = BriefingNarrator(client: brain.client, config: config, world: world)
        hud = HUDWindowController(model: notch, dismissAfter: config.profile.hud?.dismissAfterSeconds ?? 8,
                                  preferredDisplay: config.profile.hud?.preferredDisplay)
        conversation = ConversationController(notch: notch, wake: wake, transcriber: transcriber,
                                              speech: voice, config: config, modes: modes, brain: brain)
        voice.isOnline = { [weak self] in self?.brain.isOnline ?? true }
        floating?.onClose = { [weak self] in self?.conversation.stopEverything() }
        conversation.onFirstWord = { [weak self] in self?.brain.prewarmIfCold() }
        conversation.voiceID = voiceID
        brain.personalDataLocked = { [weak self] in
            await self?.ownerLock.personalDataLocked(fromPhone: RequestTrace.current?.source == "remote") ?? false
        }
        // The camera looks for the owner from the wake word until the conversation ends. Requests from
        // the phone do not switch it on: nobody is sitting at the Mac.
        conversation.$state.map { $0 != .idle }.removeDuplicates().sink { [weak self] talking in
            guard let self else { return }
            if talking, self.ownerLock.faceActive, !self.conversation.isRemoteTurn {
                let s = self.config.profile.face?.presence ?? OwnerPresence.Settings()
                self.faceWatcher.settings = { s }
                self.faceWatcher.begin("chat")
            } else {
                self.faceWatcher.end("chat")
            }
        }.store(in: &cancellables)
        conversation.onKeysNeeded = { [weak self] in self?.unlockKeys() }
        // Remote access: off until switched on, and then only on the Tailscale address.
        let speechLocale = Locale(identifier: config.profile.speech?.locale ?? "en-US")
        let remoteBackend = LiveRemoteBackend(conversation: conversation, config: config, modes: modes, router: voice, voiceID: voiceID,
                                              makeTranscriber: { TranscriberFactory.make(locale: speechLocale) })
        checkIns = PresenceCheckIns(push: PushStore(), modes: modes, notch: notch)
        remoteBackend.checkIns = checkIns
        let tokenStore = RemoteTokenStore()
        // The device layer: email, this Mac, and every paired phone or iPad, all behind the owner lock.
        devices = DeviceHub()
        devices.access = { [weak self] in
            guard let self else { return .general }
            return await self.ownerLock.access(fromPhone: RequestTrace.current?.source == "remote", wait: self.config.profile.face?.lock.decisionSeconds ?? 4).access
        }
        devices.accessAtMac = { [weak self] in
            guard let self else { return .general }
            return await self.ownerLock.access(fromPhone: false, wait: self.config.profile.face?.lock.decisionSeconds ?? 4).access
        }
        devices.register(EmailDevice(isConnected: { [gmail] in gmail!.isConnected }, unread: { [gmail] in
            let list = try await gmail!.search("is:unread in:inbox", limit: 20)
            return (list.count, list.first.map { $0.from.components(separatedBy: "<").first?.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) ?? $0.from })
        }))
        devices.register(ThisMacDevice(describe: {
            let b = SystemInfo.battery()
            return "This Mac is awake" + (b.percent.map { ", battery \($0)%" } ?? "") + (b.onBattery ? ", on battery." : ", plugged in.")
        }))
        let pushStore = checkIns!.pushStore
        devices.dynamicDevices = { [radar] in
            let subscribed = Set(pushStore.devices)
            return tokenStore.all.map { token in
                // The radar follows one phone; say where it is only for a device that looks like that phone.
                let isRadarPhone = radar.phoneID != nil && token.name.localizedCaseInsensitiveContains("iphone")
                return PairedDevice(name: token.name, lastUsed: token.lastUsed, notificationsOn: subscribed.contains(token.name),
                                    nearby: isRadarPhone ? radar.check.why : nil,
                                    push: { text in await pushStore.notify(title: "From your Mac", body: text, tag: "mac-note", onlyDevice: token.name) > 0 })
            }
        }
        devices.onMessage = { [weak self] from, text in
            guard let self else { return }
            if let text {
                self.notch.flash("Note from \(from): \(text)", seconds: 12)
                self.conversation.announceWhenIdle("A note from your \(from.localizedCaseInsensitiveContains("ipad") ? "iPad" : "phone"): \(text)")
            } else {
                self.notch.flash("A note from \(from) is waiting. It shows once the owner lock is open.", seconds: 8)
            }
        }
        remoteBackend.devices = devices
        dispatcher.register(DevicesTool(hub: devices))
        remote = RemoteAccess(config: config, tokens: tokenStore, backend: remoteBackend)
        remote.onPaired = { [weak self] name in self?.notch?.flash("Paired “\(name)” for remote access", seconds: 8) }
        remote.start()
        // A frozen main thread is not a crash, so launchd would never notice. This does.
        let supervised = supervisedByLaunchd
        hangWatchdog = HangWatchdog(timeout: config.tuning.hangTimeoutSeconds) { silent in
            JarvisLog.error("Main thread has not responded for \(Int(silent)) s. " + (supervised ? "Exiting so launchd restarts Jarvis." : "Jarvis is frozen; quit and reopen it."))
            if supervised {
                Thread.sleep(forTimeInterval: 0.3)     // let the log line reach the disk
                exit(70)
            }
        }
        hangWatchdog.start()
        if restartedAfterCrash {
            JarvisLog.warn("Previous run did not exit cleanly (crash or kill); restarted")
            // Say so once the voice is ready, so a restart is never silent.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.conversation.reportFailure("I had to restart a moment ago. I'm back.")
            }
        }
        // Microphone trouble is said out loud, once, instead of leaving Jarvis silently deaf.
        wake.onMicHealth = { [weak self] health in
            guard let self else { return }
            switch health {
            case "deaf": self.conversation.reportFailure(SpokenFailure.microphoneSilent)
            case "hearing": self.conversation.reportFailure(SpokenFailure.microphoneBack)
            case "denied": self.conversation.reportFailure(SpokenFailure.microphoneDenied)
            default: self.conversation.reportFailure(SpokenFailure.wakeFailed)
            }
        }
        // One chat at a time: when the card goes away, the conversation ends and starts fresh next time.
        notch.$phase.removeDuplicates().dropFirst().sink { [weak self] phase in
            guard let self, phase == .idle else { return }
            if !self.notch.log.isEmpty { JarvisLog.conversationEnded() }
            self.notch.log.removeAll()
            self.brain.endSession()
        }.store(in: &cancellables)
        // Mouse and keyboard control: off at every launch, on only when asked, off again by itself.
        let watcher = ControlInterruptWatcher(control: computerControl)
        let seeing = SeeingPreview()
        controlWatcher = watcher
        computerControl.onChange = { [weak self] on, message in
            self?.notch.flash(message)
            if on { watcher.start() } else { watcher.stop(); seeing.hide() }
        }
        controlTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.computerControl.expireIfDue() } }
        let computerTool = ComputerTool(control: computerControl, hands: LiveHands(), clearTheView: { [weak self] in
            if self?.hud?.isShowing == true { self?.hud?.stepAside(reason: "computer control") }
        })
        computerTool.onLook = { jpeg, app in seeing.show(jpeg: jpeg, app: app) }
        computerTool.onAct = { seeing.note($0) }
        dispatcher.register(computerTool)
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
                                    demo: demo, wake: wake, conversation: conversation, speech: speech, voice: voice, kokoro: kokoro, spotify: spotify, brain: brain, log: actionLog,
                                    googleAuth: googleAuth, notion: notion, briefing: briefing,
                                    proactive: proactive, context: context, hud: hud, scenes: scenes,
                                    memory: memory, skills: skills, local: local, narrator: narrator)
        menuBar.budget = budget
        menuBar.camera = camera
        menuBar.computerControl = computerControl
        menuBar.radar = radar
        menuBar.dispatcher = dispatcher
        radar.onChange = { [weak self] now, before in
            guard let self, before != .unknown || now == .away else { return }      // the first "near" after launch is not news
            self.notch.flash(now == .near ? "\(self.radar.phoneName) is back" : "\(self.radar.phoneName) has left")
            self.checkIns?.phoneChanged(to: now, from: before)
        }
        radar.start()
        menuBar.voiceID = voiceID
        menuBar.ownerLockApp = self
        menuBar.keys = self
        menuBar.remote = remote
        menuBar.privacy = { [weak self] in self?.dataFlows() ?? [] }
        menuBar.onEnrollVoice = { [weak self] in self?.startVoiceEnrollment() }
        JarvisLog.info("Brain: model \(brain.model), \(dispatcher.tools.count) tools, API key \(KeychainStore.apiKey() != nil ? "present" : SecretVault.shared.usesHelper && SecretVault.shared.state != .unlocked ? "locked until Touch ID" : "MISSING")")
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
                                            if q == "!prewarm" { self.brain.prewarmIfCold(force: true); return }   // silent: no HUD, no speech
                                            if q.hasPrefix("!radar survey") {     // silent: which Apple devices Bluetooth can hear, to jarvis.log
                                                Task { @MainActor in
                                                    let rows = await self.radar.runSurvey(seconds: Double(q.split(separator: " ").last ?? "") ?? 20)
                                                    JarvisLog.info("Radar survey: Bluetooth \(self.radar.bluetoothState), \(rows.count) Apple device(s)")
                                                    for r in rows.prefix(25) {
                                                        JarvisLog.info(String(format: "Radar survey: %@ name=%@ n=%d rssi=%.0f types=%@", String(r.id.uuidString.prefix(8)), r.name ?? "-", r.count, r.meanRSSI,
                                                                              r.types.sorted().map { String(format: "%02X", $0) }.joined(separator: ",")))
                                                    }
                                                }
                                                return
                                            }
                                            if q.hasPrefix("!camera") { self.cameraDebug(q); return }               // drives the camera without a model turn
                                            if q == "!voiceid enroll" { self.startVoiceEnrollment(); return }
                                            if q == "!remote pair" {        // testing: a pairing code, left in the (tool-denylisted) remote folder instead of on screen
                                                let file = RemoteTokenStore.defaultURL.deletingLastPathComponent().appendingPathComponent("pairing-debug.txt")
                                                if let offer = try? self.remote.beginPairing(name: "debug phone") {
                                                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                                                    try? Data(offer.code.utf8).write(to: file, options: .atomic)
                                                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                                                }
                                                return
                                            }
                                            if q.hasPrefix("!remote") {      // loopback: listen on 127.0.0.1 for this run only (testing); off: back to the settings
                                                self.remote.bindOverride = q.hasSuffix("loopback") ? "loopback" : nil
                                                JarvisLog.info("Debug: remote access is \(self.remote.state.line)")
                                                return
                                            }
                                            if q == "!hang" { JarvisLog.warn("Debug: freezing the main thread on purpose"); Thread.sleep(forTimeInterval: 120); return }
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
        JarvisLog.info("Privacy: " + Privacy.summary(dataFlows()))
        JarvisLog.info("Speech in: \(transcriber.name) · Speech out: \(voice.engineName) · Apple fallback: \(speech.name)")

        // JARVIS_NO_WAKE=1 skips the microphone entirely (used for CPU baselines).
        if Env.value("JARVIS_NO_WAKE") != "1" {
            Task {
                await wake.start()
                let ok = await transcriber.requestAuthorization()
                JarvisLog.info("Speech recognition permission: \(ok ? "granted" : "not granted")")
            }
        }

        let g = notchWindow.geometry
        JarvisLog.info("Notch detected=\(g.hasNotch) width=\(Int(g.notchWidth)) height=\(Int(g.notchHeight)) reduceMotion=\(notch.reduceMotion)")
    }

    // MARK: Saved keys

    /// Asks the key helper for the saved keys. The helper asks for Touch ID. Runs off the main thread, so
    /// Jarvis keeps listening while the prompt is up; until it is answered, cloud features have no keys.
    public func unlockKeys() {
        guard SecretVault.shared.usesHelper, !unlockingKeys else { return }
        unlockingKeys = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = SecretVault.shared.unlock()
            let status = SecretVault.shared.status()
            await self?.keysUnlocked(report, status)
        }
    }

    private func keysUnlocked(_ report: SecretVault.UnlockReport, _ status: (vault: [String], legacy: [String], touchID: Bool)?) {
        unlockingKeys = false
        keyStatus = status
        // Names only. A key's value never reaches a log.
        JarvisLog.info("Keys: \(report.state); available: \(report.present.joined(separator: ", "))"
                       + (report.imported.isEmpty ? "" : "; moved into the vault: \(report.imported.joined(separator: ", "))")
                       + (report.denied.isEmpty ? "" : "; not moved (prompt declined): \(report.denied.joined(separator: ", "))")
                       + (report.needsApproval.isEmpty ? "" : "; needs approval again: \(report.needsApproval.joined(separator: ", "))"))
        voice?.configure(Self.effectiveVoice(config.profile.voice))     // paid voices depend on their keys
        switch report.state {
        case .unlocked:
            if !report.imported.isEmpty {
                notch?.flash("Moved \(report.imported.count) saved key\(report.imported.count == 1 ? "" : "s") into the vault. From now on it's Touch ID, not the keychain password.", seconds: 7)
            } else if !report.denied.isEmpty {
                notch?.flash("\(report.denied.count) saved key\(report.denied.count == 1 ? " was" : "s were") not moved. Keys → Import Keys in the menu tries again.", seconds: 7)
            }
        case .locked:
            notch?.flash("Keys are locked. Choose Keys → Unlock with Touch ID in the Jarvis menu.", seconds: 6)
        case .failed(let why):
            JarvisLog.error("Keys: unlock failed: \(why)")
            notch?.flash("Couldn't unlock the saved keys: \(why)", seconds: 7)
        default: break
        }
    }

    /// Turns Touch ID for unlocking on or off. Turning it off asks for Touch ID one last time.
    public func setKeysRequireTouchID(_ on: Bool) {
        Task.detached { [weak self] in
            do {
                try SecretVault.shared.setRequiresTouchID(on)
                let status = SecretVault.shared.status()
                await self?.touchIDPolicyChanged(status, note: on ? "Touch ID is required to unlock the saved keys." : "Saved keys unlock without Touch ID now.")
            } catch {
                await self?.touchIDPolicyChanged(nil, note: "Not changed: \(error.localizedDescription)")
            }
        }
    }

    private func touchIDPolicyChanged(_ status: (vault: [String], legacy: [String], touchID: Bool)?, note: String) {
        if let status { keyStatus = status }
        notch?.flash(note, seconds: 6)
    }

    /// A few sentences on the owner lock for "is the lock on?" and the menu.
    public func ownerLockStatus() -> String {
        guard ownerLock.isActive else {
            if !SFaceEmbedder.isInstalled { return "The owner lock is off. Face recognition is not installed (scripts/setup-faceid.sh)." }
            if !faceStore.exists { return "The owner lock is off: no face is enrolled. Say \"set up face recognition\" to turn it on." }
            return "A face is enrolled but the owner lock is switched off."
        }
        if ownerLock.overrideActive, let until = ownerLock.overrideUntil {
            return "The owner lock is on and open by Touch ID until \(DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short))."
        }
        var parts: [String] = []
        if ownerLock.faceActive {
            let v = faceWatcher.verdict
            let seen = v.state == .idle ? "the camera is off until the next request" : OwnerLock.describe(v)
            parts.append("Face: \(seen)" + (v.score.map { String(format: " (score %.2f, needs %.2f)", $0, self.config.profile.face?.presence.threshold ?? 0.45) } ?? "") + ".")
        } else {
            parts.append("Face: not required.")
        }
        if ownerLock.phoneActive {
            let c = radar.check
            parts.append("Phone: \(c.why)" + (radar.tracker.smoothed.map { " (signal \(Int($0)))" } ?? "") + ".")
        } else {
            parts.append("Phone: not required.")
        }
        return "The owner lock is on. " + parts.joined(separator: " ")
    }

    /// Deletes the saved face and its key, and switches the lock off.
    public func forgetFace() throws {
        faceStore.delete()
        try config.save(faceLockEnabled: false)
        FaceLog().record("forgotten", detail: "face data deleted, lock off")
    }

    /// Runs the guided face setup as soon as Jarvis is idle. The caller has already confirmed Touch ID.
    public func startFaceEnrollment() {
        guard !faceEnrollmentPending else { return }
        faceEnrollmentPending = true
        Task { @MainActor in
            defer { faceEnrollmentPending = false }
            for _ in 0..<120 where conversation.state != .idle { try? await Task.sleep(for: .milliseconds(500)) }
            let outcome = await FaceEnrollment(watcher: faceWatcher, store: faceStore, host: conversation).run()
            JarvisLog.info("Face: enrollment finished: \(outcome)")
            switch outcome {
            case .enrolled:
                do { try config.save(faceLockEnabled: true) } catch { JarvisLog.warn("Face: could not switch the lock on: \(error.localizedDescription)") }
                FaceLog().record("enrolled", detail: "lock on")
            case .busy: notch.flash("Jarvis is busy. Try face setup again in a moment.", seconds: 5)
            case .failed: break
            }
        }
    }

    /// Runs the guided Voice ID setup as soon as Jarvis is idle (it may be mid-reply when asked).
    public func startVoiceEnrollment() {
        guard !enrollmentPending else { return }
        enrollmentPending = true
        Task { @MainActor in
            defer { enrollmentPending = false }
            for _ in 0..<120 where conversation.state != .idle { try? await Task.sleep(for: .milliseconds(500)) }
            let outcome = await VoiceEnrollment(verifier: voiceID, host: conversation).run()
            JarvisLog.info("Voice ID: enrollment finished: \(outcome)")
            if case .busy = outcome { notch.flash("Jarvis is busy. Try Voice ID setup again in a moment.", seconds: 5) }
        }
    }

    /// `!camera show | hide | frame | photo | rec <seconds> [silent] | stop` in ask.txt. Results go to jarvis.log.
    private func cameraDebug(_ command: String) {
        let parts = command.split(separator: " ").map(String.init)
        Task { @MainActor in
            do {
                switch parts.dropFirst().first ?? "" {
                case "show": try await camera.showFeed(); JarvisLog.info("Camera debug: feed visible=\(camera.isFeedVisible) running=\(camera.session.isRunning)")
                case "hide": let r = await camera.hideFeed(); JarvisLog.info("Camera debug: hidden, running=\(camera.session.isRunning), recording saved=\(r != nil)")
                case "ping": JarvisLog.info("Camera debug: main thread alive, feed=\(camera.isFeedVisible) running=\(camera.session.isRunning) recording=\(camera.isRecording)")
                case "frame":
                    let f = try await frames.source(named: "camera").captureFrame()
                    JarvisLog.info("Camera debug: frame \(f.width)x\(f.height), \(f.jpeg.count / 1024) KB, in memory only")
                case "photo": let url = try await camera.takePhoto(); JarvisLog.info("Camera debug: photo \(CameraFiles.display(url))")
                case "rec":
                    let seconds = parts.count > 2 ? Double(parts[2]) : nil
                    let started = try await camera.startRecording(seconds: seconds, audio: !parts.contains("silent"))
                    JarvisLog.info("Camera debug: recording started, limit \(Int(started.limit)) s")
                case "stop": let r = try await camera.stopRecording(); JarvisLog.info("Camera debug: stopped, \(String(format: "%.1f", r.seconds)) s, \(r.bytes / 1024) KB, \(CameraFiles.display(r.url))")
                default: JarvisLog.info("Camera debug: unknown command \(command)")
                }
            } catch {
                JarvisLog.error("Camera debug: \(command) failed: \(error.localizedDescription)")
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        remote?.stop()
        StayAwake.shared.stop()
        Supervisor.noteCleanExit()
        wake?.stop()
        kokoro?.stop()
        JarvisLog.info("Jarvis quitting")
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
