import XCTest
@testable import JarvisCore

final class ControlRulesTests: XCTestCase {
    let denied = ["Chase", "Bank of America", "PayPal", "1Password", "Keychain Access"]

    func testAppsThatAreNeverControlled() {
        for app in ["Terminal", "iTerm2", "Mail", "Messages", "System Settings", "Slack", "Discord", "Keychain Access", "1Password", "Chase", "Jarvis", "Claude", "App Store", ""] {
            XCTAssertNotNil(ControlRules.refusal(for: ScreenTarget(app: app), deniedApps: denied), app)
        }
        for app in ["Safari", "Google Chrome", "Notes", "Finder", "Preview", "Spotify", "Arc"] {
            XCTAssertNil(ControlRules.refusal(for: ScreenTarget(app: app, windowTitle: "cheap flights to Seattle - Google Search"), deniedApps: denied), app)
        }
    }

    func testAMoneyOrPasswordPageInAnOrdinaryBrowserIsRefused() {
        for title in ["Chase Online - Sign in", "PayPal: Send Money", "Checkout - Amazon.com", "Online Banking | Wells", "Passwords - Settings", "Bank of America | Accounts", "Billing – GitHub"] {
            XCTAssertNotNil(ControlRules.refusal(for: ScreenTarget(app: "Safari", windowTitle: title), deniedApps: denied), title)
        }
        XCTAssertNil(ControlRules.refusal(for: ScreenTarget(app: "Safari", windowTitle: "River bankside walks, purchased maps"), deniedApps: denied), "whole words only")
    }

    func testClicksThatNeedAYes() {
        for label in ["Send", "Place order", "Buy now", "Delete forever", "Sign in", "Post · button", "Submit", "Add to cart · Checkout", "Log in with Google", "Accept all", "Download"] {
            XCTAssertNotNil(ControlRules.riskyWord(in: ElementInfo(role: "AXButton", label: label)), label)
        }
        for label in ["Images", "Next page", "cheap flights to Seattle", "Resend-free zone".replacingOccurrences(of: "Resend", with: "Blend"), "Postpone".replacingOccurrences(of: "Post", with: "Most"), ""] {
            XCTAssertNil(ControlRules.riskyWord(in: ElementInfo(role: "AXLink", label: label)), label)
        }
        XCTAssertNil(ControlRules.riskyWord(in: nil))
    }

    func testReturnIsOnlyFreeInASearchBoxOrTheAddressBar() {
        XCTAssertFalse(ControlRules.returnNeedsYes(focused: ElementInfo(role: "AXTextField", subrole: "AXSearchField")))
        XCTAssertFalse(ControlRules.returnNeedsYes(focused: ElementInfo(role: "AXTextField", label: "Address and search bar")))
        XCTAssertFalse(ControlRules.returnNeedsYes(focused: ElementInfo(role: "AXComboBox", label: "Search")))
        XCTAssertTrue(ControlRules.returnNeedsYes(focused: ElementInfo(role: "AXTextArea", label: "Message")))
        XCTAssertTrue(ControlRules.returnNeedsYes(focused: nil), "if it cannot be told, ask")
    }

    func testTyping() {
        let field = ElementInfo(role: "AXTextField", label: "Search")
        XCTAssertNil(ControlRules.refusal(forTyping: "cheap flights to Seattle", into: field))
        XCTAssertNotNil(ControlRules.refusal(forTyping: "hunter2", into: ElementInfo(role: "AXTextField", subrole: "AXSecureTextField")))
        XCTAssertNotNil(ControlRules.refusal(forTyping: String(repeating: "a", count: 501), into: field))
        XCTAssertNotNil(ControlRules.refusal(forTyping: "sk-ant-api03-" + String(repeating: "A1b2", count: 12), into: field))
        XCTAssertNotNil(ControlRules.refusal(forTyping: "line one\nline two", into: field), "a new line is a Return")
    }

    func testKeys() {
        XCTAssertEqual(KeyStroke.parse("return")?.keyCode, 36)
        let k = KeyStroke.parse("Cmd + Shift + T")
        XCTAssertEqual(k?.keyCode, 17); XCTAssertTrue(k?.command == true && k?.shift == true)
        XCTAssertNil(KeyStroke.parse("hyper+x")); XCTAssertNil(KeyStroke.parse("f13")); XCTAssertNil(KeyStroke.parse(""))
        for bad in ["cmd+v", "cmd+ctrl+q", "cmd+shift+q", "cmd+opt+esc", "cmd+space", "cmd+tab"] {
            XCTAssertNotNil(ControlRules.refusal(for: KeyStroke.parse(bad)!), bad)
        }
        for fine in ["cmd+l", "cmd+t", "tab", "down", "cmd+c", "escape"] { XCTAssertNil(ControlRules.refusal(for: KeyStroke.parse(fine)!), fine) }
    }

    func testLookingTwiceIsNotALoopButStillCountsTowardTheBudget() {
        var g = LoopGuard(budget: 3)
        XCTAssertNil(g.check(tool: "computer", input: ["action": "look"]))
        XCTAssertNil(g.check(tool: "computer", input: ["action": "look"]))
        XCTAssertNil(g.check(tool: "computer", input: ["action": "look"]))
        XCTAssertNotNil(g.check(tool: "computer", input: ["action": "look"]), "the budget still ends it")
        var other = LoopGuard()
        XCTAssertNil(other.check(tool: "weather", input: [:]))
        XCTAssertNotNil(other.check(tool: "weather", input: [:]))
    }

    func testPictureCoordinatesBecomeScreenPoints() {
        let g = ScreenShot.Geometry(imageWidth: 1280, imageHeight: 800, origin: CGPoint(x: -1920, y: 0), pointWidth: 1920, pointHeight: 1200)
        XCTAssertEqual(ControlRules.screenPoint(x: 640, y: 400, shot: g), CGPoint(x: -960, y: 600))
        XCTAssertNil(ControlRules.screenPoint(x: 1281, y: 10, shot: g))
        XCTAssertNil(ControlRules.screenPoint(x: -1, y: 10, shot: g))
    }
}

@MainActor
final class FakeHands: ComputerHands {
    var hasPermission = true
    var asked = 0
    var target = ScreenTarget(app: "Safari", windowTitle: "Google")
    var focused: ElementInfo? = ElementInfo(role: "AXTextField", label: "Search")
    var under: ElementInfo? = ElementInfo(role: "AXLink", label: "Images")
    var did: [String] = []
    var excluded: [String] = []
    func requestPermission() { asked += 1 }
    func front() -> ScreenTarget { target }
    func focusedElement() -> ElementInfo? { focused }
    func element(at point: CGPoint) -> ElementInfo? { under }
    func capture(excludingApps: [String]) async throws -> ScreenShot {
        excluded = excludingApps; did.append("look")
        return ScreenShot(jpeg: Data([0xFF, 0xD8]), geometry: .init(imageWidth: 1280, imageHeight: 800, pointWidth: 1440, pointHeight: 900))
    }
    func click(at point: CGPoint, count: Int) { did.append("click \(Int(point.x)),\(Int(point.y)) x\(count)") }
    func type(_ text: String) { did.append("type \(text)") }
    func press(_ key: KeyStroke) { did.append("key \(key.name)") }
    func scroll(at point: CGPoint?, lines: Int) { did.append("scroll \(lines)") }
}

@MainActor
final class ComputerToolTests: XCTestCase {
    var hands: FakeHands!
    var control: ComputerControl!
    var clock = Date(timeIntervalSince1970: 1_000_000)
    var dispatcher: ToolDispatcher!
    var asked: [String] = []
    var answer = true
    var logURL: URL!

    override func setUp() async throws {
        hands = FakeHands(); asked = []; answer = true
        clock = Date(timeIntervalSince1970: 1_000_000)
        control = ComputerControl(now: { [unowned self] in self.clock })
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        let notch = NotchViewModel()
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID()).log")
        dispatcher = ToolDispatcher(config: config, context: ToolContext(config: config, modes: ModeManager(config: config, notch: notch), undo: UndoStack(), notch: notch), log: ActionLog(url: logURL))
        dispatcher.register(ComputerTool(control: control, hands: hands, settleMilliseconds: 0))
        dispatcher.approvalHandler = { [unowned self] r in self.asked.append(r.preview); return self.answer }
    }
    override func tearDown() { try? FileManager.default.removeItem(at: logURL) }

    func call(_ input: JSONObject, source: ToolCallSource = .user) async -> ToolResult { await dispatcher.call("computer", input: input, source: source) }

    func testItIsOffUntilAskedAndNothingMovesWhileOff() async {
        for input: JSONObject in [["action": "look"], ["action": "click", "x": 5, "y": 5], ["action": "type", "text": "hi"], ["action": "key", "key": "return"], ["action": "scroll"]] {
            let r = await call(input)
            XCTAssertTrue(r.isError && r.content.contains("Computer control is off"), r.content)
        }
        XCTAssertTrue(hands.did.isEmpty)
        XCTAssertTrue(asked.isEmpty)
    }

    func testASearchFromStartToFinish() async {
        var r = await call(["action": "enable"])
        XCTAssertFalse(r.isError, r.content)
        r = await call(["action": "look"])
        XCTAssertEqual(r.images.count, 1)
        XCTAssertEqual(asked, ["Use the mouse and keyboard in Safari"], "one yes for the app")
        XCTAssertTrue(hands.excluded.contains("mail") && hands.excluded.contains("Chase"), "private apps are left out of the picture")
        _ = await call(["action": "click", "x": 640, "y": 400])
        _ = await call(["action": "type", "text": "cheap flights to Seattle"])
        r = await call(["action": "key", "key": "return"])
        XCTAssertFalse(r.isError, r.content)
        XCTAssertEqual(hands.did, ["look", "click 720,450 x1", "type cheap flights to Seattle", "key return"])
        XCTAssertEqual(asked.count, 1, "Return in a search box and an ordinary click need no further yes")
    }

    func testARiskyClickAndAReturnOutsideSearchNeedAYesAndANoStopsThem() async {
        _ = await call(["action": "enable"]); _ = await call(["action": "look"])
        asked = []; answer = false
        hands.under = ElementInfo(role: "AXButton", label: "Place order")
        var r = await call(["action": "click", "x": 10, "y": 10])
        XCTAssertTrue(r.isError)
        hands.focused = ElementInfo(role: "AXTextArea", label: "Comment")
        r = await call(["action": "key", "key": "return"])
        XCTAssertTrue(r.isError)
        XCTAssertEqual(asked.map { $0.components(separatedBy: ". Note:")[0] }, ["Click “Place order” in Safari", "Press Return in Safari (Google)"])
        XCTAssertEqual(hands.did, ["look"], "nothing was clicked or pressed")
    }

    func testBlockedAppsAndPagesArePutDownBeforeAnyQuestion() async {
        _ = await call(["action": "enable"])
        for target in [ScreenTarget(app: "Terminal"), ScreenTarget(app: "Messages"), ScreenTarget(app: "Safari", windowTitle: "Chase Online - Sign in"), ScreenTarget(app: "1Password")] {
            hands.target = target
            for input: JSONObject in [["action": "look"], ["action": "type", "text": "x"], ["action": "key", "key": "tab"]] {
                let r = await call(input)
                XCTAssertTrue(r.isError, "\(target.app) \(input)")
            }
        }
        XCTAssertTrue(hands.did.isEmpty)
        XCTAssertTrue(asked.isEmpty)
    }

    func testPasswordFieldsAndPasteAreNeverTouched() async {
        _ = await call(["action": "enable"]); _ = await call(["action": "look"])
        hands.focused = ElementInfo(role: "AXTextField", subrole: "AXSecureTextField")
        var r = await call(["action": "type", "text": "anything"])
        XCTAssertTrue(r.isError && r.content.contains("password field"), r.content)
        hands.under = ElementInfo(role: "AXTextField", subrole: "AXSecureTextField", label: "Password")
        r = await call(["action": "click", "x": 3, "y": 3])
        XCTAssertTrue(r.isError)
        r = await call(["action": "key", "key": "cmd+v"])
        XCTAssertTrue(r.isError)
        XCTAssertEqual(hands.did, ["look"])
    }

    func testItTurnsItselfOffAndEscWinsOverAnOpenQuestion() async {
        _ = await call(["action": "enable", "minutes": 5]); _ = await call(["action": "look"])
        clock += 301
        var r = await call(["action": "type", "text": "late"])
        XCTAssertTrue(r.isError && r.content.contains("Computer control is off"), r.content)
        XCTAssertFalse(control.isEnabled)
        // On again; Sam presses Esc while Jarvis is asking about a click.
        _ = await call(["action": "enable"]); _ = await call(["action": "look"])
        hands.under = ElementInfo(role: "AXButton", label: "Send")
        dispatcher.approvalHandler = { [unowned self] _ in self.control.disable(reason: "Esc"); return true }
        r = await call(["action": "click", "x": 3, "y": 3])
        XCTAssertTrue(r.isError && r.content.contains("turned off"), r.content)
        XCTAssertFalse(hands.did.contains { $0.hasPrefix("click") })
    }

    func testNeverFromThePhoneATimerOrAnInjectedInstruction() async {
        var r = await call(["action": "enable"], source: .proactive)
        XCTAssertTrue(r.isError)
        let remote = RequestTrace(source: "remote", sink: TraceSink(file: nil))
        r = await RequestTrace.$current.withValue(remote) { await call(["action": "enable"]) }
        XCTAssertTrue(r.isError && r.content.contains("not from the phone"), r.content)
        let tainted = RequestTrace(source: "text", sink: TraceSink(file: nil))
        tainted.markUntrusted("an email")
        answer = false
        r = await RequestTrace.$current.withValue(tainted) { await call(["action": "enable"]) }
        XCTAssertTrue(r.isError)
        XCTAssertFalse(control.isEnabled)
        XCTAssertEqual(asked, ["Turn on mouse and keyboard control. Note: I read an email before asking this"])
    }

    func testWithoutMacOSPermissionItAsksSamAndStaysOff() async {
        hands.hasPermission = false
        let r = await call(["action": "enable"])
        XCTAssertTrue(r.isError && r.content.contains("Accessibility"), r.content)
        XCTAssertEqual(hands.asked, 1)
        XCTAssertFalse(control.isEnabled)
    }

    func testLookingMarksTheRequestAsHavingReadTheScreen() async {
        let trace = RequestTrace(source: "text", sink: TraceSink(file: nil))
        _ = await RequestTrace.$current.withValue(trace) { await call(["action": "enable"]) }
        _ = await RequestTrace.$current.withValue(trace) { await call(["action": "look"]) }
        XCTAssertEqual(trace.untrustedSources, ["the screen"])
    }
}
