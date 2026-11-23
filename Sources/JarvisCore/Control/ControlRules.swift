import CoreGraphics
import Foundation

/// What is in front of the user right now.
public struct ScreenTarget: Equatable, Sendable {
    public var app: String
    public var windowTitle: String
    public init(app: String, windowTitle: String = "") { self.app = app; self.windowTitle = windowTitle }
}

/// One thing on screen, as the accessibility system describes it.
public struct ElementInfo: Equatable, Sendable {
    public var role: String
    public var subrole: String
    /// Its title and description, and those of the things it sits inside (a label inside a button).
    public var label: String
    public init(role: String = "", subrole: String = "", label: String = "") { self.role = role; self.subrole = subrole; self.label = label }
    public var isPasswordField: Bool { subrole == "AXSecureTextField" }
    public var isSearchOrAddressField: Bool {
        let l = label.lowercased()
        return subrole == "AXSearchField" || l.contains("search") || l.contains("address")
    }
}

public struct KeyStroke: Equatable, Sendable {
    public var keyCode: CGKeyCode
    public var command = false, shift = false, option = false, control = false
    public var name: String

    static let codes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
    ]

    /// "cmd+shift+t", "return", "Tab". Nil for anything that is not one known key with known modifiers.
    public static func parse(_ text: String) -> KeyStroke? {
        let parts = text.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, let code = codes[last] else { return nil }
        var k = KeyStroke(keyCode: code, name: text.lowercased().replacingOccurrences(of: " ", with: ""))
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command", "meta": k.command = true
            case "shift": k.shift = true
            case "opt", "option", "alt": k.option = true
            case "ctrl", "control": k.control = true
            default: return nil
            }
        }
        return k
    }

    public var isReturn: Bool { keyCode == 36 }
    var hasModifier: Bool { command || option || control }
}

/// Every rule about what computer control may touch, in one place and free of any system call, so each
/// one is tested. The tool asks these questions before it moves the mouse or presses a key.
public enum ControlRules {
    public static let defaultMinutes = 10
    public static let maxMinutes = 30
    public static let maxTypedCharacters = 500

    /// Apps computer control never works in, whatever denylist.json says. Typing into a terminal is running
    /// shell commands; a mail or chat app is sending messages; System Settings is changing settings. Each of
    /// those already has its own tool with its own approval, or is off limits.
    static let blockedApps = ["terminal", "iterm", "iterm2", "warp", "kitty", "alacritty", "ghostty", "hyper", "wezterm",
                              "system settings", "system preferences", "keychain access", "passwords", "wallet",
                              "mail", "messages", "facetime", "whatsapp", "telegram", "signal", "slack", "discord", "outlook",
                              "microsoft teams", "zoom", "messenger", "app store", "script editor", "automator", "shortcuts",
                              "activity monitor", "console", "disk utility", "migration assistant", "jarvis", "claude",
                              "xcode", "visual studio code", "code", "cursor"]

    /// Words in a window title that mean money or passwords are on screen.
    static let blockedTitleWords = ["bank", "banking", "checkout", "payment", "payments", "wallet", "password", "passwords", "keychain",
                                    "paypal", "venmo", "zelle", "coinbase", "robinhood", "1password", "bitwarden", "lastpass", "billing"]

    /// Words on a button or link that mean pressing it sends, spends, removes, or signs something.
    static let riskyWords = ["send", "post", "publish", "tweet", "reply", "buy", "pay", "purchase", "order", "checkout", "subscribe",
                             "donate", "transfer", "delete", "remove", "erase", "discard", "submit", "confirm", "sign in", "log in", "login",
                             "sign up", "register", "install", "download", "allow", "agree", "accept", "authorize", "approve", "share",
                             "unsubscribe", "cancel subscription", "place order", "book", "reserve", "apply", "save password", "empty trash"]

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        let w = words(text), p = words(phrase)
        guard !p.isEmpty, w.count >= p.count else { return false }
        return (0...(w.count - p.count)).contains { Array(w[$0..<($0 + p.count)]) == p }
    }

    /// Why this app or window is off limits, or nil.
    public static func refusal(for target: ScreenTarget, deniedApps: [String]) -> String? {
        let app = target.app.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty else { return "I can't tell which app is in front, so I won't touch it." }
        if blockedApps.contains(app) { return "I don't use the mouse or keyboard in \(target.app)." }
        for d in deniedApps where app == d.lowercased() || app.contains(d.lowercased()) { return "\(target.app) is on the never-touch list." }
        for d in deniedApps where d.count >= 4 && containsPhrase(target.windowTitle, d) { return "That window is about \(d), which is on the never-touch list." }
        for w in blockedTitleWords where containsPhrase(target.windowTitle, w) { return "That window looks like it has money or passwords on it (“\(w)”), so I won't touch it." }
        return nil
    }

    /// The word that makes a click need a yes, or nil for an ordinary click.
    public static func riskyWord(in element: ElementInfo?) -> String? {
        guard let label = element?.label, !label.isEmpty else { return nil }
        return riskyWords.first { containsPhrase(label, $0) }
    }

    /// Return submits things. It is only free in a search box or the address bar.
    public static func returnNeedsYes(focused: ElementInfo?) -> Bool { !(focused?.isSearchOrAddressField ?? false) }

    /// Key combinations that are never pressed: paste (the clipboard may hold a password), lock, log out, force quit.
    public static func refusal(for key: KeyStroke) -> String? {
        if key.command, key.keyCode == 9 { return "I don't paste: the clipboard may hold something private." }
        if key.command, key.control, key.keyCode == 12 { return "I don't lock the screen." }
        if key.command, key.shift, key.keyCode == 12 { return "I don't log you out." }
        if key.command, key.option, key.keyCode == 53 { return "I don't open Force Quit." }
        if key.command, key.keyCode == 49 || key.keyCode == 48 { return "I don't switch apps or open Spotlight with the keyboard. Ask me to open the app instead." }
        return nil
    }

    public static func refusal(forTyping text: String, into focused: ElementInfo?) -> String? {
        if focused?.isPasswordField == true { return "That is a password field. I never type into those." }
        if text.count > maxTypedCharacters { return "That is too long to type (\(text.count) characters; the limit is \(maxTypedCharacters))." }
        if !SecretRedactor.redact(text).kinds.isEmpty { return "That looks like a password or a key. I won't type it." }
        if text.contains(where: { $0.isNewline }) { return "I type one line at a time; a new line would press Return." }
        return nil
    }

    /// A point in the picture the model saw, as a point on the real screen.
    public static func screenPoint(x: Double, y: Double, shot: ScreenShot.Geometry) -> CGPoint? {
        guard x >= 0, y >= 0, x <= Double(shot.imageWidth), y <= Double(shot.imageHeight), shot.imageWidth > 0, shot.imageHeight > 0 else { return nil }
        return CGPoint(x: shot.origin.x + x * shot.pointWidth / Double(shot.imageWidth),
                       y: shot.origin.y + y * shot.pointHeight / Double(shot.imageHeight))
    }
}

public struct ScreenShot: Sendable {
    public struct Geometry: Equatable, Sendable {
        public var imageWidth: Int, imageHeight: Int
        /// The display's place and size in screen points (top-left origin, as mouse events use).
        public var origin: CGPoint
        public var pointWidth: Double, pointHeight: Double
        public init(imageWidth: Int, imageHeight: Int, origin: CGPoint = .zero, pointWidth: Double, pointHeight: Double) {
            self.imageWidth = imageWidth; self.imageHeight = imageHeight; self.origin = origin; self.pointWidth = pointWidth; self.pointHeight = pointHeight
        }
    }
    public var jpeg: Data
    public var geometry: Geometry
    public init(jpeg: Data, geometry: Geometry) { self.jpeg = jpeg; self.geometry = geometry }
}

/// The hands and eyes. The real one uses Accessibility, Quartz events, and ScreenCaptureKit; tests use a fake.
@MainActor
public protocol ComputerHands: AnyObject {
    var hasPermission: Bool { get }
    /// Shows macOS's own "allow Jarvis to control this computer" prompt. Only the user can say yes to it.
    func requestPermission()
    func front() -> ScreenTarget
    func focusedElement() -> ElementInfo?
    func element(at point: CGPoint) -> ElementInfo?
    /// One picture of the display the front window is on, without Jarvis's own windows and without any
    /// window of the named apps.
    func capture(excludingApps: [String]) async throws -> ScreenShot
    func click(at point: CGPoint, count: Int)
    func type(_ text: String)
    func press(_ key: KeyStroke)
    func scroll(at point: CGPoint?, lines: Int)
}

/// Whether computer control is switched on. Off at launch, on only when Sam asks, off again by itself.
@MainActor
public final class ComputerControl: ObservableObject {
    @Published public private(set) var enabledUntil: Date?
    /// Apps Sam has said yes to in this session.
    public private(set) var grantedApps: Set<String> = []
    public var lastShot: ScreenShot.Geometry?
    /// When Jarvis last moved the mouse or pressed a key. The user touching either right after that stops it.
    public var lastActionAt: Date?
    public var onChange: ((Bool, String) -> Void)?
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) { self.now = now }

    public var isEnabled: Bool { if let until = enabledUntil { return now() < until } else { return false } }
    public var minutesLeft: Int { max(0, Int(((enabledUntil?.timeIntervalSince(now()) ?? 0) / 60).rounded(.up))) }

    public func enable(minutes: Int) {
        let m = min(ControlRules.maxMinutes, max(1, minutes))
        enabledUntil = now().addingTimeInterval(Double(m) * 60)
        grantedApps = []; lastShot = nil
        JarvisLog.info("Computer control: on for \(m) min")
        onChange?(true, "Computer control on for \(m) min. Esc turns it off.")
    }

    public func disable(reason: String) {
        guard enabledUntil != nil else { return }
        enabledUntil = nil; grantedApps = []; lastShot = nil; lastActionAt = nil
        JarvisLog.info("Computer control: off (\(reason))")
        onChange?(false, "Computer control off")
    }

    public func grant(_ app: String) { grantedApps.insert(app.lowercased()) }
    public func isGranted(_ app: String) -> Bool { grantedApps.contains(app.lowercased()) }
    /// Expired sessions are cleared the next time anyone asks.
    public func expireIfDue() { if enabledUntil != nil, !isEnabled { disable(reason: "time is up") } }
}
