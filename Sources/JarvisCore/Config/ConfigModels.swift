import Foundation

// MARK: - profile.json

/// Personal facts about the user. Everything here is editable in config/profile.json.
public struct Profile: Codable, Equatable {
    public struct Routine: Codable, Equatable {
        public var workoutStart: String
        public var workoutEnd: String
        public var transport: String
    }
    public struct Assistant: Codable, Equatable {
        public var name: String
        public var addressUserAs: String
        public var tone: String
        public var spokenReplyMaxSentences: Int
        public var voiceIdentifier: String?
        public var speechRate: Double
        /// "ironman" adds the JARVIS mannerisms to the system prompt.
        public var persona: String?
    }
    public struct WakePhrase: Codable, Equatable {
        public var phrase: String
        public var aliases: [String]
        public var scene: String
    }
    public struct Wake: Codable, Equatable {
        public var phrases: [WakePhrase]
        public var arrivalWindowMinutes: Int
        public var alwaysSpotPhrases: Bool
        public var homecomingOnHeyJarvis: Bool
        private enum CodingKeys: String, CodingKey { case phrases, arrivalWindowMinutes, alwaysSpotPhrases, homecomingOnHeyJarvis }
        public init(phrases: [WakePhrase] = [], arrivalWindowMinutes: Int = 10, alwaysSpotPhrases: Bool = false, homecomingOnHeyJarvis: Bool = true) {
            self.phrases = phrases; self.arrivalWindowMinutes = arrivalWindowMinutes; self.alwaysSpotPhrases = alwaysSpotPhrases; self.homecomingOnHeyJarvis = homecomingOnHeyJarvis
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            phrases = try c.decodeIfPresent([WakePhrase].self, forKey: .phrases) ?? []
            arrivalWindowMinutes = try c.decodeIfPresent(Int.self, forKey: .arrivalWindowMinutes) ?? 10
            alwaysSpotPhrases = try c.decodeIfPresent(Bool.self, forKey: .alwaysSpotPhrases) ?? false
            homecomingOnHeyJarvis = try c.decodeIfPresent(Bool.self, forKey: .homecomingOnHeyJarvis) ?? true
        }
    }
    public struct World: Codable, Equatable {
        public var weatherCity: String?
        public var units: String
        public var headlines: Int
        private enum CodingKeys: String, CodingKey { case weatherCity, units, headlines }
        public init(weatherCity: String? = nil, units: String = "celsius", headlines: Int = 2) { self.weatherCity = weatherCity; self.units = units; self.headlines = headlines }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            weatherCity = try c.decodeIfPresent(String.self, forKey: .weatherCity)
            units = try c.decodeIfPresent(String.self, forKey: .units) ?? "celsius"
            headlines = try c.decodeIfPresent(Int.self, forKey: .headlines) ?? 2
        }
    }
    /// Local model through Ollama: used offline, or always in Private Mode.
    public struct Local: Codable, Equatable {
        public var enabled: Bool
        public var model: String
        public var baseURL: String
        public var privateMode: Bool
        private enum CodingKeys: String, CodingKey { case enabled, model, baseURL, privateMode }
        public init(enabled: Bool = true, model: String = "qwen3.5:9b", baseURL: String = "http://127.0.0.1:11434", privateMode: Bool = false) {
            self.enabled = enabled; self.model = model; self.baseURL = baseURL; self.privateMode = privateMode
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? "qwen3.5:9b"
            baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? "http://127.0.0.1:11434"
            privateMode = try c.decodeIfPresent(Bool.self, forKey: .privateMode) ?? false
        }
    }
    public struct MemoryConfig: Codable, Equatable {
        public var enabled: Bool
        public var archiveConversations: Bool
        private enum CodingKeys: String, CodingKey { case enabled, archiveConversations }
        public init(enabled: Bool = true, archiveConversations: Bool = true) { self.enabled = enabled; self.archiveConversations = archiveConversations }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            archiveConversations = try c.decodeIfPresent(Bool.self, forKey: .archiveConversations) ?? true
        }
    }
    /// How Jarvis shows itself. style "floating" = a card on the active screen; "notch" = the original notch island.
    public struct UI: Codable, Equatable {
        public var style: String
        /// "active" = the screen under the mouse, or a display name like "Odyssey G5" to pin it.
        public var screen: String
        public var position: String
        public var halo: Bool
        private enum CodingKeys: String, CodingKey { case style, screen, position, halo }
        public init(style: String = "floating", screen: String = "active", position: String = "bottom", halo: Bool = false) {
            self.style = style; self.screen = screen; self.position = position; self.halo = halo
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            style = try c.decodeIfPresent(String.self, forKey: .style) ?? "floating"
            screen = try c.decodeIfPresent(String.self, forKey: .screen) ?? "active"
            position = try c.decodeIfPresent(String.self, forKey: .position) ?? "bottom"
            halo = try c.decodeIfPresent(Bool.self, forKey: .halo) ?? false
        }
    }
    /// Text-to-speech engine. "auto" = ElevenLabs if a key is set, else OpenAI if a key is set, else the best Apple voice.
    public struct Voice: Codable, Equatable {
        public var engine: String
        public var elevenLabsVoiceId: String
        public var elevenLabsModel: String
        public var openAIVoice: String
        public var openAIInstructions: String
        /// Kokoro (free, on-device): bm_george, bm_lewis, bm_daniel, bm_fable are British male.
        public var kokoroVoice: String = "bm_george"
        public var kokoroSpeed: Double = 1.0
        private enum CodingKeys: String, CodingKey { case engine, elevenLabsVoiceId, elevenLabsModel, openAIVoice, openAIInstructions, kokoroVoice, kokoroSpeed }
        public init(engine: String = "auto", elevenLabsVoiceId: String = "onwK4e9ZLuTAKqWW03F9", elevenLabsModel: String = "eleven_flash_v2_5",
                    openAIVoice: String = "fable", openAIInstructions: String = Voice.defaultInstructions) {
            self.engine = engine; self.elevenLabsVoiceId = elevenLabsVoiceId; self.elevenLabsModel = elevenLabsModel
            self.openAIVoice = openAIVoice; self.openAIInstructions = openAIInstructions
        }
        public static let defaultInstructions = "Speak as JARVIS: a refined British AI butler. Smooth, warm, calm and measured, with a hint of dry wit. Natural pacing, never robotic."
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "auto"
            elevenLabsVoiceId = try c.decodeIfPresent(String.self, forKey: .elevenLabsVoiceId) ?? "onwK4e9ZLuTAKqWW03F9"
            elevenLabsModel = try c.decodeIfPresent(String.self, forKey: .elevenLabsModel) ?? "eleven_flash_v2_5"
            openAIVoice = try c.decodeIfPresent(String.self, forKey: .openAIVoice) ?? "fable"
            openAIInstructions = try c.decodeIfPresent(String.self, forKey: .openAIInstructions) ?? Voice.defaultInstructions
            kokoroVoice = try c.decodeIfPresent(String.self, forKey: .kokoroVoice) ?? "bm_george"
            kokoroSpeed = try c.decodeIfPresent(Double.self, forKey: .kokoroSpeed) ?? 1.0
        }
    }
    public struct HUD: Codable, Equatable {
        public var fullScreenAlways: Bool
        public var fullScreenForScenes: Bool
        public var dismissAfterSeconds: Double
        /// Display name (as macOS shows it, e.g. "Odyssey G5") the HUD prefers when connected. Falls back to the notch screen.
        public var preferredDisplay: String?
        private enum CodingKeys: String, CodingKey { case fullScreenAlways, fullScreenForScenes, dismissAfterSeconds, preferredDisplay }
        public init(fullScreenAlways: Bool = false, fullScreenForScenes: Bool = true, dismissAfterSeconds: Double = 8, preferredDisplay: String? = nil) {
            self.fullScreenAlways = fullScreenAlways; self.fullScreenForScenes = fullScreenForScenes; self.dismissAfterSeconds = dismissAfterSeconds
            self.preferredDisplay = preferredDisplay
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fullScreenAlways = try c.decodeIfPresent(Bool.self, forKey: .fullScreenAlways) ?? false
            fullScreenForScenes = try c.decodeIfPresent(Bool.self, forKey: .fullScreenForScenes) ?? true
            dismissAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .dismissAfterSeconds) ?? 8
            preferredDisplay = try c.decodeIfPresent(String.self, forKey: .preferredDisplay)
        }
    }
    public struct Briefing: Codable, Equatable {
        public var time: String
        public var onFirstUnlock: Bool
        public var examLookaheadDays: Int
        public var deadlineCount: Int
        public var nudgeDaysBefore: [Int]
    }
    public struct Claude: Codable, Equatable {
        public var model: String
        public var maxTokens: Int
    }
    /// Notion data source ids + property names. All optional with Student OS defaults so older configs parse.
    public struct Notion: Codable, Equatable {
        public var homeworkDataSourceId: String = ""
        public var examsDataSourceId: String = ""
        public var classesDataSourceId: String = ""
        public var notesParentPageId: String = ""
        public var homeworkTitleProperty: String = "Assignment"
        public var homeworkDueProperty: String = "Due"
        public var homeworkStatusProperty: String = "Status"
        public var homeworkDoneValues: [String] = ["Submitted", "Graded"]
        public var examsTitleProperty: String = "Exam"
        public var examsDateProperty: String = "Date"

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case homeworkDataSourceId, examsDataSourceId, classesDataSourceId, notesParentPageId
            case homeworkTitleProperty, homeworkDueProperty, homeworkStatusProperty, homeworkDoneValues, examsTitleProperty, examsDateProperty
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            homeworkDataSourceId = try c.decodeIfPresent(String.self, forKey: .homeworkDataSourceId) ?? ""
            examsDataSourceId = try c.decodeIfPresent(String.self, forKey: .examsDataSourceId) ?? ""
            classesDataSourceId = try c.decodeIfPresent(String.self, forKey: .classesDataSourceId) ?? ""
            notesParentPageId = try c.decodeIfPresent(String.self, forKey: .notesParentPageId) ?? ""
            homeworkTitleProperty = try c.decodeIfPresent(String.self, forKey: .homeworkTitleProperty) ?? "Assignment"
            homeworkDueProperty = try c.decodeIfPresent(String.self, forKey: .homeworkDueProperty) ?? "Due"
            homeworkStatusProperty = try c.decodeIfPresent(String.self, forKey: .homeworkStatusProperty) ?? "Status"
            homeworkDoneValues = try c.decodeIfPresent([String].self, forKey: .homeworkDoneValues) ?? ["Submitted", "Graded"]
            examsTitleProperty = try c.decodeIfPresent(String.self, forKey: .examsTitleProperty) ?? "Exam"
            examsDateProperty = try c.decodeIfPresent(String.self, forKey: .examsDateProperty) ?? "Date"
        }
    }
    public struct DataSources: Codable, Equatable {
        public var calendar: String
        public var email: String
        public var notion: Notion
        public var codeFolders: [String]
    }
    /// Optional so configs written before Milestone 3 still parse.
    public struct Speech: Codable, Equatable {
        public var locale: String
        public var silenceEndSeconds: Double
        public var noSpeechTimeoutSeconds: Double
        public var maxUtteranceSeconds: Double
        /// After a reply, keep listening this long for a follow-up (no wake word needed). 0 disables.
        public var followUpSeconds: Double
        /// Talking over Jarvis stops it and starts a new turn.
        public var interruptOnSpeech: Bool

        private enum CodingKeys: String, CodingKey { case locale, silenceEndSeconds, noSpeechTimeoutSeconds, maxUtteranceSeconds, followUpSeconds, interruptOnSpeech }
        public init(locale: String, silenceEndSeconds: Double, noSpeechTimeoutSeconds: Double, maxUtteranceSeconds: Double,
                    followUpSeconds: Double = 7, interruptOnSpeech: Bool = true) {
            self.locale = locale; self.silenceEndSeconds = silenceEndSeconds; self.noSpeechTimeoutSeconds = noSpeechTimeoutSeconds
            self.maxUtteranceSeconds = maxUtteranceSeconds; self.followUpSeconds = followUpSeconds; self.interruptOnSpeech = interruptOnSpeech
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? "en-US"
            silenceEndSeconds = try c.decodeIfPresent(Double.self, forKey: .silenceEndSeconds) ?? 1.3
            noSpeechTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .noSpeechTimeoutSeconds) ?? 6
            maxUtteranceSeconds = try c.decodeIfPresent(Double.self, forKey: .maxUtteranceSeconds) ?? 20
            followUpSeconds = try c.decodeIfPresent(Double.self, forKey: .followUpSeconds) ?? 7
            interruptOnSpeech = try c.decodeIfPresent(Bool.self, forKey: .interruptOnSpeech) ?? true
        }
    }
    public struct Proactive: Codable, Equatable {
        public var breakReminders: Bool
        public var breakAfterMinutes: Int
        public var quietHoursStart: String
        public var quietHoursEnd: String
        public var autoModes: Bool = true
        public var manualOverrideHours: Double = 2
        public var callApps: [String] = PresenceDetector.defaultCallApps

        public init(breakReminders: Bool, breakAfterMinutes: Int, quietHoursStart: String, quietHoursEnd: String,
                    autoModes: Bool = true, manualOverrideHours: Double = 2, callApps: [String] = PresenceDetector.defaultCallApps) {
            self.breakReminders = breakReminders; self.breakAfterMinutes = breakAfterMinutes
            self.quietHoursStart = quietHoursStart; self.quietHoursEnd = quietHoursEnd
            self.autoModes = autoModes; self.manualOverrideHours = manualOverrideHours; self.callApps = callApps
        }

        private enum CodingKeys: String, CodingKey { case breakReminders, breakAfterMinutes, quietHoursStart, quietHoursEnd, autoModes, manualOverrideHours, callApps }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            breakReminders = try c.decodeIfPresent(Bool.self, forKey: .breakReminders) ?? false
            breakAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .breakAfterMinutes) ?? 90
            quietHoursStart = try c.decodeIfPresent(String.self, forKey: .quietHoursStart) ?? "22:30"
            quietHoursEnd = try c.decodeIfPresent(String.self, forKey: .quietHoursEnd) ?? "06:00"
            autoModes = try c.decodeIfPresent(Bool.self, forKey: .autoModes) ?? true
            manualOverrideHours = try c.decodeIfPresent(Double.self, forKey: .manualOverrideHours) ?? 2
            callApps = try c.decodeIfPresent([String].self, forKey: .callApps) ?? PresenceDetector.defaultCallApps
        }
    }

    public var name: String
    public var fullName: String
    public var school: String
    public var city: String
    public var graduationYear: Int
    public var goal: String
    public var homeTimeZone: String
    public var secondaryTimeZone: String
    public var routine: Routine
    public var assistant: Assistant
    public var briefing: Briefing
    public var claude: Claude
    public var dataSources: DataSources
    public var proactive: Proactive
    public var speech: Speech?
    public var wake: Wake?
    public var hud: HUD?
    public var world: World?
    public var local: Local?
    public var memory: MemoryConfig?
    public var ui: UI?
    public var voice: Voice?

    /// Used when profile.json is missing or malformed so the app still launches.
    public static let fallback = Profile(
        name: "Sam", fullName: "Samarth", school: "University of Arizona", city: "Tucson",
        graduationYear: 2029, goal: "software engineering internship",
        homeTimeZone: "America/Phoenix", secondaryTimeZone: "Asia/Singapore",
        routine: Routine(workoutStart: "06:00", workoutEnd: "06:30", transport: "bike"),
        assistant: Assistant(name: "Jarvis", addressUserAs: "Sam", tone: "JARVIS from Iron Man: composed, dry British wit, unflappable",
                             spokenReplyMaxSentences: 2, voiceIdentifier: nil, speechRate: 0.52, persona: "ironman"),
        briefing: Briefing(time: "07:00", onFirstUnlock: true, examLookaheadDays: 14, deadlineCount: 3, nudgeDaysBefore: [7, 3, 1, 0]),
        claude: Claude(model: "claude-sonnet-5-5", maxTokens: 1024),
        dataSources: DataSources(calendar: "eventkit", email: "gmail",
                                 notion: Notion(), codeFolders: ["~/Developer"]),
        proactive: Proactive(breakReminders: false, breakAfterMinutes: 90, quietHoursStart: "22:30", quietHoursEnd: "06:00"),
        speech: Speech(locale: "en-US", silenceEndSeconds: 1.3, noSpeechTimeoutSeconds: 6, maxUtteranceSeconds: 20),
        wake: Wake(phrases: [WakePhrase(phrase: "wake up daddy's home", aliases: ["daddy's home", "daddy is home"], scene: "homecoming")]),
        hud: HUD(preferredDisplay: nil),
        world: World(), local: Local(), memory: MemoryConfig(), ui: UI(), voice: Voice()
    )
}

// MARK: - allowed-folders.json

public struct AllowedFolders: Codable, Equatable, Sendable {
    public var read: [String]
    public var organize: [String]
    public var sortedFolderName: String
    public var largeFileMB: Int
    public var oldFileDays: Int

    public static let fallback = AllowedFolders(read: ["~/Developer", "~/Desktop", "~/Downloads", "~/Documents"],
                                                organize: ["~/Desktop", "~/Downloads"],
                                                sortedFolderName: "Sorted", largeFileMB: 500, oldFileDays: 90)
}

// MARK: - denylist.json  (Tier 3)

public struct Denylist: Codable, Equatable, Sendable {
    public var paths: [String]
    public var filePatterns: [String]
    public var apps: [String]
    public var shellPatterns: [String]

    private enum CodingKeys: String, CodingKey { case paths, filePatterns, apps, shellPatterns }

    public init(paths: [String], filePatterns: [String], apps: [String], shellPatterns: [String]) {
        self.paths = paths; self.filePatterns = filePatterns; self.apps = apps; self.shellPatterns = shellPatterns
    }

    /// The hard floor: even if denylist.json is deleted, these stay denied.
    public static let fallback = Denylist(
        paths: ["~/.ssh", "~/Library/Keychains", "~/.aws", "~/.gnupg", "/System", "/Library", "/private", "/etc", "/usr"],
        filePatterns: [".env", ".env.*", "*.pem", "*.key", "id_rsa*", "id_ed25519*", "credentials.json"],
        apps: ["Keychain Access", "1Password", "Passwords"],
        shellPatterns: ["sudo", "rm -rf /", "mkfs", "csrutil", "security ", "| sh", "| bash"]
    )
}

// MARK: - modes.json

public struct Place: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var latitude: Double?
    public var longitude: Double?
    public var radiusMeters: Double
    public var wifiSSIDs: [String]
}

public struct ModeDefinition: Codable, Equatable, Identifiable {
    public struct Triggers: Codable, Equatable {
        public var places: [String]
        public var pluggedIn: Bool?
        public var externalDisplay: Bool?
        public var calendarKeywords: [String]
    }
    public struct Voice: Codable, Equatable {
        public var enabled: Bool
        public var volume: Double
    }
    public struct Notch: Codable, Equatable {
        public var glow: Double
        public var showFullDay: Bool
    }
    /// What Jarvis applies automatically on entering the mode. All reversible, all Tier 1.
    public struct Setup: Codable, Equatable {
        public var focus: String?
        public var volume: Double?
        public var brightness: Double?
        public var quitApps: [String]
        public var hideApps: [String]
        public var openApps: [String]
        public var muteNotifications: Bool
    }

    public var id: String
    public var name: String
    public var icon: String
    public var triggers: Triggers
    public var voice: Voice
    public var notch: Notch
    public var briefing: [String]
    public var holdNotifications: Bool
    public var pollingMinutes: Int
    public var allowedTools: [String]
    public var lowBatteryWarnPercent: Int?
    public var setup: Setup
}

public struct ModesConfig: Codable, Equatable {
    public var defaultMode: String
    public var places: [Place]
    public var modes: [ModeDefinition]

    private enum CodingKeys: String, CodingKey { case defaultMode, places, modes }

    public init(defaultMode: String, places: [Place], modes: [ModeDefinition]) {
        self.defaultMode = defaultMode; self.places = places; self.modes = modes
    }

    public func mode(id: String) -> ModeDefinition? { modes.first { $0.id == id } }

    public static let fallback = ModesConfig(
        defaultMode: "home",
        places: [],
        modes: [ModeDefinition(
            id: "home", name: "Home", icon: "house.fill",
            triggers: .init(places: [], pluggedIn: nil, externalDisplay: nil, calendarKeywords: []),
            voice: .init(enabled: true, volume: 0.8), notch: .init(glow: 1, showFullDay: true),
            briefing: ["tasks", "deadlines", "exams"], holdNotifications: false, pollingMinutes: 10,
            allowedTools: ["*"], lowBatteryWarnPercent: nil,
            setup: .init(focus: nil, volume: nil, brightness: nil, quitApps: [], hideApps: [], openApps: [], muteNotifications: false))]
    )
}
