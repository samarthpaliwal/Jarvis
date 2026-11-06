import AppKit
import AVFoundation

/// The menu bar item. Status, mode switching, Do Not Disturb, demos, config, launch at login.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let config: ConfigStore
    private let notch: NotchViewModel
    private let notchWindow: NotchWindowController
    private let modes: ModeManager
    private let demo: DemoDriver
    private let wake: WakeWordService
    private let conversation: ConversationController
    private let speech: AppleSpeechOutput
    private let voice: SpeechRouter
    private let kokoro: KokoroService
    private let spotify: SpotifySearch
    private let brain: Brain
    private let actionLog: ActionLog
    private let googleAuth: GoogleAuth
    private let notion: NotionClient
    private let briefing: BriefingService
    private let proactive: ProactiveScheduler
    private let context: ContextDetector
    private let hud: HUDWindowController
    private let scenes: SceneDirector
    private let memory: MemoryStore
    private let skills: SkillLibrary
    private let local: OllamaClient
    private let narrator: BriefingNarrator
    private var localStatus = "checking…"
    private let menu = NSMenu()

    public init(config: ConfigStore, notch: NotchViewModel, notchWindow: NotchWindowController,
                modes: ModeManager, demo: DemoDriver, wake: WakeWordService,
                conversation: ConversationController, speech: AppleSpeechOutput, voice: SpeechRouter, kokoro: KokoroService, spotify: SpotifySearch, brain: Brain, log: ActionLog,
                googleAuth: GoogleAuth, notion: NotionClient, briefing: BriefingService,
                proactive: ProactiveScheduler, context: ContextDetector, hud: HUDWindowController, scenes: SceneDirector,
                memory: MemoryStore, skills: SkillLibrary, local: OllamaClient, narrator: BriefingNarrator) {
        self.memory = memory
        self.skills = skills
        self.local = local
        self.narrator = narrator
        self.proactive = proactive
        self.context = context
        self.hud = hud
        self.scenes = scenes
        self.conversation = conversation
        self.speech = speech
        self.voice = voice
        self.kokoro = kokoro
        self.spotify = spotify
        self.brain = brain
        self.actionLog = log
        self.googleAuth = googleAuth
        self.notion = notion
        self.briefing = briefing
        self.config = config
        self.notch = notch
        self.notchWindow = notchWindow
        self.modes = modes
        self.demo = demo
        self.wake = wake
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Jarvis")
            button.image?.isTemplate = true
            button.toolTip = "Jarvis"
        }
        menu.delegate = self
        statusItem.menu = menu
        notch.doNotDisturb = UserDefaults.standard.bool(forKey: "jarvis.doNotDisturb")
    }

    // Rebuild on every open so status text and checkmarks are fresh.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !config.errors.isEmpty {
            for e in config.errors {
                let item = NSMenuItem(title: "⚠︎ \(e)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        let wakeStatus = NSMenuItem(title: wakeLine, action: nil, keyEquivalent: "")
        wakeStatus.isEnabled = false
        menu.addItem(wakeStatus)
        if let line = turnLine {
            let t = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            t.isEnabled = false
            menu.addItem(t)
        }
        menu.addItem(.separator())

        // Brain
        let brainLine = NSMenuItem(title: "Claude: \(brain.model) · key \(KeychainStore.apiKey() == nil ? "missing" : "in Keychain") · \(brain.isOnline ? "online" : "offline")", action: nil, keyEquivalent: "")
        brainLine.isEnabled = false
        menu.addItem(brainLine)
        menu.addItem(ClosureMenuItem(title: "Set API Key…", symbol: "key") { [notch] in
            MenuBarController.promptForAPIKey(notch: notch)
        })
        menu.addItem(ClosureMenuItem(title: "Clear Conversation", symbol: "eraser") { [brain] in brain.clearHistory() })
        let convo = ClosureMenuItem(title: "Conversation Mode (follow-ups without “Hey Jarvis”)", symbol: "bubble.left.and.bubble.right") { [conversation] in
            conversation.conversationMode.toggle()
        }
        convo.state = conversation.conversationMode ? .on : .off
        menu.addItem(convo)
        let hudItem = ClosureMenuItem(title: "Full-Screen HUD for Every Conversation", symbol: "rectangle.inset.filled") { [hud] in
            hud.fullScreenAlways.toggle()
        }
        hudItem.state = hud.fullScreenAlways ? .on : .off
        menu.addItem(hudItem)
        menu.addItem(ClosureMenuItem(title: "Show HUD Now", symbol: "sparkles.rectangle.stack") { [hud] in hud.show(scene: false) })
        let displays = NSScreen.screens.map(\.localizedName)
        let target = NotchGeometry.screen(named: hud.preferredDisplay)?.localizedName ?? NotchGeometry.preferredScreen()?.localizedName ?? "?"
        let disp = NSMenuItem(title: "HUD display: \(target)\(hud.preferredDisplay.map { " (prefers \($0))" } ?? "") · connected: \(displays.joined(separator: ", "))", action: nil, keyEquivalent: "")
        disp.isEnabled = false
        menu.addItem(disp)
        menu.addItem(ClosureMenuItem(title: "Run Homecoming Scene", symbol: "house.and.flag") { [scenes] in scenes.homecoming(trigger: "menu") })
        menu.addItem(ClosureMenuItem(title: "Ask by Text…", symbol: "keyboard") { [conversation] in
            let alert = NSAlert()
            alert.messageText = "Ask Jarvis"
            alert.addButton(withTitle: "Ask"); alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
            field.placeholderString = "What's left today?"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            conversation.ask(field.stringValue)
        })
        menu.addItem(ClosureMenuItem(title: "Briefing Now", symbol: "sun.max") { [briefing, modes, conversation, narrator] in
            Task {
                let r = await briefing.build(mode: modes.current)
                conversation.deliver(await narrator.narrate(r, kind: "briefing on request"), cards: [.briefing(r.data)])
            }
        })

        // Memory, skills, local model (ported from OpenJarvis)
        let mem = NSMenu()
        let counts = NSMenuItem(title: "\(memory.entries(.profile).count) profile · \(memory.entries(.facts).count) facts · \(memory.count()) indexed", action: nil, keyEquivalent: "")
        counts.isEnabled = false
        mem.addItem(counts)
        mem.addItem(ClosureMenuItem(title: "Open Memory Folder (MEMORY.md, USER.md)", symbol: "folder") { [memory] in NSWorkspace.shared.open(memory.directory) })
        mem.addItem(ClosureMenuItem(title: "Forget Conversation History", symbol: "trash") { [memory, notch] in
            memory.clearConversations(); notch.flash("Conversation history forgotten. Facts and profile kept.")
        })
        let memItem = NSMenuItem(title: "Memory", action: nil, keyEquivalent: "")
        memItem.image = NSImage(systemSymbolName: "brain", accessibilityDescription: nil)
        memItem.submenu = mem
        menu.addItem(memItem)

        let sk = NSMenu()
        for s in skills.all { let i = NSMenuItem(title: "\(s.name): \(s.description.prefix(60))", action: nil, keyEquivalent: ""); i.isEnabled = false; sk.addItem(i) }
        if skills.all.isEmpty { let i = NSMenuItem(title: "No skills installed", action: nil, keyEquivalent: ""); i.isEnabled = false; sk.addItem(i) }
        sk.addItem(.separator())
        sk.addItem(ClosureMenuItem(title: "Open Skills Folder", symbol: "folder") { [skills] in
            try? FileManager.default.createDirectory(at: skills.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(skills.directory)
        })
        sk.addItem(ClosureMenuItem(title: "Reload Skills", symbol: "arrow.clockwise") { [skills, notch] in skills.reload(); notch.flash("\(skills.all.count) skill(s) loaded") })
        let skItem = NSMenuItem(title: "Skills (\(skills.all.count))", action: nil, keyEquivalent: "")
        skItem.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
        skItem.submenu = sk
        menu.addItem(skItem)

        let priv = ClosureMenuItem(title: "Private Mode (local model only, nothing to the cloud)", symbol: "lock.shield") { [brain, notch] in
            brain.privateMode.toggle()
            notch.flash(brain.privateMode ? "Private Mode on: local model only" : "Private Mode off")
        }
        priv.state = brain.privateMode ? .on : .off
        menu.addItem(priv)
        let ls = NSMenuItem(title: "Local model: \(local.model) · \(localStatus)", action: nil, keyEquivalent: "")
        ls.isEnabled = false
        menu.addItem(ls)
        Task { [weak self, local] in
            let s = await local.status()
            self?.localStatus = !s.running ? "Ollama not running" : s.hasModel ? "ready" : "not pulled (ollama pull \(local.model))"
        }

        // Integrations
        let integ = NSMenu()
        let gmailState = googleAuth.isConnected ? "connected" : googleAuth.isConfigured ? "client set, not signed in" : "not set up"
        let g = NSMenuItem(title: "Gmail: \(gmailState)", action: nil, keyEquivalent: ""); g.isEnabled = false; integ.addItem(g)
        integ.addItem(ClosureMenuItem(title: "Set Google OAuth Client…", symbol: "person.badge.key") { [notch] in
            MenuBarController.promptForGoogleClient(notch: notch)
        })
        integ.addItem(ClosureMenuItem(title: googleAuth.isConnected ? "Reconnect Gmail…" : "Connect Gmail…", symbol: "envelope") { [googleAuth, notch] in
            Task {
                do { try await googleAuth.connect(); notch.flash("Gmail connected") }
                catch { notch.flash("Gmail: \(error.localizedDescription)", seconds: 6) }
            }
        })
        if googleAuth.isConnected {
            integ.addItem(ClosureMenuItem(title: "Disconnect Gmail", symbol: "envelope.badge.shield.half.filled") { [googleAuth, notch] in
                googleAuth.disconnect(); notch.flash("Gmail disconnected")
            })
        }
        integ.addItem(.separator())
        let sp = NSMenuItem(title: "Spotify search: \(spotify.isConfigured ? "ready (one-step play by name)" : "not set up (opens search instead)")", action: nil, keyEquivalent: ""); sp.isEnabled = false; integ.addItem(sp)
        integ.addItem(ClosureMenuItem(title: "Set Spotify Client…", symbol: "music.note") { [notch] in
            MenuBarController.promptForSpotifyClient(notch: notch)
        })
        integ.addItem(.separator())
        let n = NSMenuItem(title: "Notion: \(notion.isConfigured ? "connected" : "not connected")", action: nil, keyEquivalent: ""); n.isEnabled = false; integ.addItem(n)
        integ.addItem(ClosureMenuItem(title: "Connect Notion…", symbol: "doc.text") { [notch] in
            MenuBarController.promptForSecret(title: "Notion integration token",
                                              info: "Create an internal integration at notion.so/profile/integrations, share your Student OS page with it, and paste the secret. Stored in the Keychain.",
                                              account: NotionClient.tokenAccount, notch: notch)
        })
        let integItem = NSMenuItem(title: "Integrations", action: nil, keyEquivalent: "")
        integItem.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        integItem.submenu = integ
        menu.addItem(integItem)
        menu.addItem(ClosureMenuItem(title: "What Did You Do Today?", symbol: "list.bullet.clipboard") { [actionLog, notch] in
            let lines = actionLog.todaySummary()
            notch.respond(lines.isEmpty ? "Nothing yet today." : "\(lines.count) action(s) today.",
                          cards: lines.isEmpty ? [] : [.info(title: "Today", lines: Array(lines.suffix(8)))], collapseAfter: 12)
        })
        menu.addItem(.separator())

        // Voice
        let voiceMenu = NSMenu()
        let mute = ClosureMenuItem(title: "Speak Replies", symbol: "speaker.wave.2") { [conversation] in
            conversation.voiceMuted.toggle()
        }
        mute.state = conversation.voiceMuted ? .off : .on
        voiceMenu.addItem(mute)
        voiceMenu.addItem(ClosureMenuItem(title: "Test Voice", symbol: "play") { [conversation, config] in
            conversation.deliver("Hi \(config.profile.assistant.addressUserAs), this is the voice I’ll use.")
        })
        voiceMenu.addItem(ClosureMenuItem(title: "Stop Talking", symbol: "stop.circle") { [conversation] in
            conversation.stopEverything()
        })
        voiceMenu.addItem(.separator())
        let eng = NSMenuItem(title: "Engine: \(voice.engineName)", action: nil, keyEquivalent: "")
        eng.isEnabled = false
        voiceMenu.addItem(eng)
        let current = UserDefaults.standard.string(forKey: "jarvis.voiceEngine") ?? config.profile.voice?.engine ?? "auto"
        for (id, label) in [("auto", "Best available"), ("kokoro", "Kokoro: free, on-device neural (\(kokoro.status))"),
                            ("elevenlabs", "ElevenLabs (key needed)"), ("openai", "OpenAI (key needed)"), ("apple", "Apple basic voice")] {
            let item = ClosureMenuItem(title: label) { [voice, config, notch] in
                UserDefaults.standard.set(id, forKey: "jarvis.voiceEngine")
                voice.configure(AppDelegate.effectiveVoice(config.profile.voice))
                notch.flash("Voice: \(voice.engineName)")
            }
            item.state = current == id ? .on : .off
            voiceMenu.addItem(item)
        }
        let kv = UserDefaults.standard.string(forKey: "jarvis.kokoroVoice") ?? config.profile.voice?.kokoroVoice ?? "bm_george"
        let kMenu = NSMenu()
        for (id, label) in [("bm_george", "George (British, warm)"), ("bm_lewis", "Lewis (British, deeper)"), ("bm_daniel", "Daniel (British, crisp)"), ("bm_fable", "Fable (British, storyteller)"), ("am_michael", "Michael (American)"), ("am_onyx", "Onyx (American, deep)")] {
            let item = ClosureMenuItem(title: label) { [voice, config, conversation] in
                UserDefaults.standard.set(id, forKey: "jarvis.kokoroVoice")
                voice.configure(AppDelegate.effectiveVoice(config.profile.voice))
                conversation.deliver("Good evening, \(config.profile.assistant.addressUserAs). This is how I'll sound.")
            }
            item.state = kv == id ? .on : .off
            kMenu.addItem(item)
        }
        let kItem = NSMenuItem(title: "Kokoro Voice", action: nil, keyEquivalent: "")
        kItem.submenu = kMenu
        voiceMenu.addItem(kItem)
        voiceMenu.addItem(ClosureMenuItem(title: "Set ElevenLabs Key…", symbol: "key") { [voice, config, notch] in
            MenuBarController.promptForSecret(title: "ElevenLabs API key", info: "From elevenlabs.io → Profile → API keys. Stored in the Keychain. Replies are sent to ElevenLabs to be spoken.",
                                              account: CloudSpeechOutput.elevenLabsKeyAccount, notch: notch)
            voice.configure(AppDelegate.effectiveVoice(config.profile.voice))
        })
        voiceMenu.addItem(ClosureMenuItem(title: "Set OpenAI Key…", symbol: "key") { [voice, config, notch] in
            MenuBarController.promptForSecret(title: "OpenAI API key", info: "From platform.openai.com → API keys. Stored in the Keychain. Replies are sent to OpenAI to be spoken.",
                                              account: CloudSpeechOutput.openAIKeyAccount, notch: notch)
            voice.configure(AppDelegate.effectiveVoice(config.profile.voice))
        })
        voiceMenu.addItem(ClosureMenuItem(title: "Get Better Apple Voices…", symbol: "arrow.down.circle") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent") { NSWorkspace.shared.open(url) }
        })
        voiceMenu.addItem(.separator())
        let appleHeader = NSMenuItem(title: "Apple voices (used when no cloud voice):", action: nil, keyEquivalent: "")
        appleHeader.isEnabled = false
        voiceMenu.addItem(appleHeader)
        for v in VoicePicker.candidates().prefix(14) {
            let item = ClosureMenuItem(title: "\(v.name) · \(v.language) · \(VoicePicker.label(v))") { [speech] in
                speech.voice = AVSpeechSynthesisVoice(identifier: v.identifier)
                UserDefaults.standard.set(v.identifier, forKey: "jarvis.voice")
                JarvisLog.info("Voice set to \(v.name) (\(v.identifier))")
            }
            item.state = speech.voice?.identifier == v.identifier ? .on : .off
            voiceMenu.addItem(item)
        }
        voiceMenu.addItem(.separator())
        let hint = NSMenuItem(title: "More voices: System Settings → Accessibility → Spoken Content", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        voiceMenu.addItem(hint)
        let voiceItem = NSMenuItem(title: "Voice: \(voice.engineName.hasPrefix("AVSpeech") ? (speech.voice?.name ?? "default") : voice.engineName)", action: nil, keyEquivalent: "")
        voiceItem.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)

        // Wake word
        switch wake.state {
        case .listening, .paused:
            let pause = ClosureMenuItem(title: "Wake Word Listening", symbol: "ear") { [wake] in
                wake.setPaused(wake.state == .listening)
            }
            pause.state = wake.state == .listening ? .on : .off
            menu.addItem(pause)
        case .micDenied:
            menu.addItem(ClosureMenuItem(title: "Open Microphone Privacy Settings…", symbol: "mic.slash") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            })
        case .stopped, .failed:
            menu.addItem(ClosureMenuItem(title: "Start Wake Word", symbol: "ear") { [wake] in
                Task { await wake.start() }
            })
        case .starting:
            break
        }
        menu.addItem(ClosureMenuItem(title: "Wake Jarvis Now (test)", symbol: "hand.wave") { [wake] in
            wake.simulateWake()
        })
        menu.addItem(.separator())

        // Modes
        let modeMenu = NSMenu()
        for mode in modes.available {
            let item = ClosureMenuItem(title: mode.name, symbol: mode.icon) { [modes] in
                modes.switchTo(id: mode.id, reason: "menu")
            }
            item.state = mode.id == modes.current.id ? .on : .off
            modeMenu.addItem(item)
        }
        modeMenu.addItem(.separator())
        let auto = ClosureMenuItem(title: "Automatic (location, Wi-Fi, power, calendar)", symbol: "location") { [modes, context] in
            modes.clearManualOverride()
            Task { await context.refresh(reason: "menu") }
        }
        auto.state = modes.manualUntil == nil ? .on : .off
        modeMenu.addItem(auto)
        if let why = modes.lastAutoReason {
            let r = NSMenuItem(title: "Last auto: \(why)", action: nil, keyEquivalent: ""); r.isEnabled = false; modeMenu.addItem(r)
        }
        if let until = modes.manualUntil, until > Date() {
            let f = DateFormatter(); f.timeStyle = .short
            let r = NSMenuItem(title: "Manual until \(f.string(from: until))", action: nil, keyEquivalent: ""); r.isEnabled = false; modeMenu.addItem(r)
        }
        let modeItem = NSMenuItem(title: "Mode: \(modes.current.name)\(modes.manualUntil == nil ? "" : " (manual)")", action: nil, keyEquivalent: "")
        modeItem.image = NSImage(systemSymbolName: modes.current.icon, accessibilityDescription: nil)
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let dnd = ClosureMenuItem(title: "Do Not Disturb Jarvis", symbol: "moon.fill") { [notch] in
            notch.doNotDisturb.toggle()
            UserDefaults.standard.set(notch.doNotDisturb, forKey: "jarvis.doNotDisturb")
            JarvisLog.info("Do Not Disturb \(notch.doNotDisturb ? "on" : "off")")
        }
        dnd.state = notch.doNotDisturb ? .on : .off
        menu.addItem(dnd)
        let breaks = ClosureMenuItem(title: "Break Reminders", symbol: "figure.walk") { [config, notch] in
            // Toggle in the user's profile.json so it survives restarts.
            let url = config.directory.appendingPathComponent("profile.json")
            if let d = try? Data(contentsOf: url), var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               var p = o["proactive"] as? [String: Any] {
                p["breakReminders"] = !((p["breakReminders"] as? Bool) ?? false)
                o["proactive"] = p
                if let out = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) { try? out.write(to: url) }
                config.reload()
                notch.flash("Break reminders \(config.profile.proactive.breakReminders ? "on" : "off")")
            }
        }
        breaks.state = config.profile.proactive.breakReminders ? .on : .off
        menu.addItem(breaks)
        let quiet = NSMenuItem(title: "Quiet hours \(config.profile.proactive.quietHoursStart)–\(config.profile.proactive.quietHoursEnd)\(proactive.isQuietHours ? " (now)" : "")" + (proactive.status.suppressedBy.map { " · silent: \($0)" } ?? ""), action: nil, keyEquivalent: "")
        quiet.isEnabled = false
        menu.addItem(quiet)
        menu.addItem(.separator())

        // Demos (until the real pipeline exists)
        let demoMenu = NSMenu()
        demoMenu.addItem(ClosureMenuItem(title: "Full conversation", symbol: "play.circle") { [demo] in demo.runConversation() })
        demoMenu.addItem(ClosureMenuItem(title: "Morning briefing card", symbol: "sun.max") { [demo] in demo.runBriefing() })
        demoMenu.addItem(ClosureMenuItem(title: "Listening (hold)", symbol: "mic") { [demo] in demo.runListening() })
        demoMenu.addItem(ClosureMenuItem(title: "Thinking (hold)", symbol: "sparkles") { [demo] in demo.runThinking() })
        demoMenu.addItem(ClosureMenuItem(title: "One-line confirmation", symbol: "text.bubble") { [demo] in demo.runOneLiner() })
        demoMenu.addItem(.separator())
        demoMenu.addItem(ClosureMenuItem(title: "Collapse", symbol: "xmark.circle") { [demo, notch] in demo.cancel(); notch.collapse() })
        let demoItem = NSMenuItem(title: "Demo Notch", action: nil, keyEquivalent: "")
        demoItem.submenu = demoMenu
        menu.addItem(demoItem)
        menu.addItem(.separator())

        // Config & maintenance
        menu.addItem(ClosureMenuItem(title: "Open Config Folder", symbol: "folder") { [config] in
            NSWorkspace.shared.open(config.directory)
        })
        menu.addItem(ClosureMenuItem(title: "Open Logs Folder", symbol: "doc.text") {
            NSWorkspace.shared.open(JarvisLog.logDirectory)
        })
        menu.addItem(ClosureMenuItem(title: "Reload Config", symbol: "arrow.clockwise") { [config, notch] in
            config.reload()
            notch.flash(config.errors.isEmpty ? "Config reloaded" : "Config reloaded with \(config.errors.count) error(s)")
        })
        menu.addItem(ClosureMenuItem(title: "Re-measure Notch", symbol: "rectangle.topthird.inset.filled") { [notchWindow] in
            notchWindow.reposition(reason: "manual")
        })
        menu.addItem(.separator())

        let login = ClosureMenuItem(title: "Launch at Login", symbol: "power") { [weak self] in
            guard let self else { return }
            if !LaunchAtLogin.set(!LaunchAtLogin.isEnabled) {
                self.notch.flash("Launch at login needs the built Jarvis.app (see README)")
            }
        }
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        login.isEnabled = LaunchAtLogin.isAvailable
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private var wakeLine: String {
        var line = "Wake word: \(wake.state.label)"
        if wake.stats.chunks > 0 {
            line += String(format: " · %.1f ms/chunk · peak %.2f · %d heard",
                           wake.stats.averageInferenceMs, wake.stats.peakScore, wake.stats.detections)
        }
        return line
    }

    /// Secure text field in an alert. The key goes straight to the Keychain and is never logged.
    static func promptForAPIKey(notch: NotchViewModel) {
        let alert = NSAlert()
        alert.messageText = "Anthropic API key"
        alert.informativeText = "Stored in your login Keychain as “Jarvis ANTHROPIC_API_KEY”. Jarvis reads only this item."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Paste from Clipboard & Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "sk-ant-…  (⌘V works here too)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        var key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if response == .alertSecondButtonReturn || key.isEmpty {
            key = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard key.hasPrefix("sk-ant-") else {
            notch.flash(key.isEmpty ? "Clipboard is empty" : "That doesn’t look like an Anthropic key (should start with sk-ant-)", seconds: 5)
            return
        }
        guard !key.isEmpty else { return }
        do {
            try KeychainStore.write(key)
            notch.flash("API key saved to Keychain")
            JarvisLog.info("API key stored in Keychain")
        } catch {
            notch.flash("Couldn’t save key: \(error.localizedDescription)", seconds: 6)
        }
    }

    static func promptForSecret(title: String, info: String, account: String, notch: NotchViewModel) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Paste from Clipboard & Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "⌘V works here too"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        var v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if response == .alertSecondButtonReturn || v.isEmpty {
            v = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !v.isEmpty else { notch.flash("Clipboard is empty"); return }
        do { try KeychainStore.write(v, account: account); notch.flash("\(title) saved to Keychain") }
        catch { notch.flash("Couldn’t save: \(error.localizedDescription)", seconds: 6) }
    }

    static func promptForSpotifyClient(notch: NotchViewModel) {
        let alert = NSAlert()
        alert.messageText = "Spotify client (for playing songs by name)"
        alert.informativeText = "developer.spotify.com/dashboard → Create app (any name; redirect URI http://127.0.0.1:8888/callback; tick Web API) → Settings. Paste the Client ID and Client secret. Stored in the Keychain. No Spotify login is needed."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 380, height: 56))
        stack.orientation = .vertical
        let id = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24)); id.placeholderString = "Client ID (⌘V works)"
        let secret = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24)); secret.placeholderString = "Client secret"
        stack.addArrangedSubview(id); stack.addArrangedSubview(secret)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = id
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let cid = id.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), cs = secret.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cid.isEmpty, !cs.isEmpty else { notch.flash("Both fields are needed"); return }
        do {
            try KeychainStore.write(cid, account: SpotifySearch.clientIDAccount)
            try KeychainStore.write(cs, account: SpotifySearch.clientSecretAccount)
            notch.flash("Spotify search ready. Try “Hey Jarvis, play Thunderstruck”.", seconds: 5)
        } catch { notch.flash("Couldn’t save: \(error.localizedDescription)", seconds: 6) }
    }

    static func promptForGoogleClient(notch: NotchViewModel) {
        let alert = NSAlert()
        alert.messageText = "Google OAuth client (Desktop app)"
        alert.informativeText = "From console.cloud.google.com → APIs & Services → Credentials → Create OAuth client ID → Desktop app. Enable the Gmail API first. Both values are stored in the Keychain."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 380, height: 56))
        stack.orientation = .vertical
        let id = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24)); id.placeholderString = "Client ID (…apps.googleusercontent.com)"
        let secret = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24)); secret.placeholderString = "Client secret"
        stack.addArrangedSubview(id); stack.addArrangedSubview(secret)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = id
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let cid = id.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cid.isEmpty else { return }
        do {
            try KeychainStore.write(cid, account: GoogleAuth.clientIDAccount)
            try KeychainStore.write(secret.stringValue, account: GoogleAuth.clientSecretAccount)
            notch.flash("Google client saved. Now choose Connect Gmail…", seconds: 5)
        } catch { notch.flash("Couldn’t save: \(error.localizedDescription)", seconds: 6) }
    }

    private var turnLine: String? {
        let t = conversation.lastTurn
        guard t.wakeToFirstWordMs != nil || t.endOfSpeechToReplyMs != nil else { return nil }
        var parts: [String] = []
        if let a = t.wakeToFirstWordMs { parts.append(String(format: "wake→first word %.0f ms", a)) }
        if let b = t.endOfSpeechToReplyMs { parts.append(String(format: "end→reply %.0f ms", b)) }
        if let r = t.endReason { parts.append("ended: \(r)") }
        if !t.toolCalls.isEmpty { parts.append("tools: \(t.toolCalls.joined(separator: ","))") }
        if t.tokens.0 > 0 { parts.append("tokens \(t.tokens.0)/\(t.tokens.1)") }
        return "Last turn: " + parts.joined(separator: " · ")
    }

    private var statusLine: String {
        let g = notchWindow.geometry
        let where_ = g.hasNotch ? "notch \(Int(g.notchWidth))×\(Int(g.notchHeight))" : "no notch, floating pill"
        return "Jarvis · \(conversation.state.rawValue) · \(where_)"
    }
}

/// NSMenuItem that runs a closure. Keeps the menu code free of selector plumbing.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}
