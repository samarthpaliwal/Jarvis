import XCTest
@testable import JarvisCore

final class OpenWebsiteRulesTests: XCTestCase {
    func ok(_ s: String, _ denied: [String] = []) -> String? { try? OpenWebsiteTool.resolve(s, deniedApps: denied).get().absoluteString }

    func testOrdinarySites() {
        XCTAssertEqual(ok("youtube.com"), "https://youtube.com")
        XCTAssertEqual(ok("https://github.com/samarthpaliwal/Jarvis"), "https://github.com/samarthpaliwal/Jarvis")
        XCTAssertEqual(ok("http://example.org/a?b=c"), "https://example.org/a?b=c", "plain http is upgraded")
        XCTAssertEqual(ok("  d2l.arizona.edu  "), "https://d2l.arizona.edu")
    }

    func testOnlyPublicHTTPSPages() {
        for bad in ["", "localhost", "localhost:8787", "127.0.0.1", "192.168.1.1", "http://10.0.0.5/admin", "[::1]", "printer.local", "router.lan",
                    "file:///etc/passwd", "javascript:alert(1)", "ftp://example.com", "x-apple.systempreferences:com.apple.preference.security",
                    "shortcuts://run-shortcut?name=x", "example.com:8080", "two words.com", "nodot", "https://user:pw@example.com", "https://sam@example.com",
                    "100.64.0.9", "my-mac.tail1234.ts.net:8787", String(repeating: "a", count: 400) + ".com"] {
            XCTAssertNil(ok(bad), bad)
        }
    }

    func testMoneyAndPasswordSitesAreRefused() {
        let denied = ["Chase", "Bank of America", "PayPal", "1Password", "Wise", "Venmo"]
        for bad in ["chase.com", "https://secure.chase.com/login", "www.bankofamerica.com", "paypal.com/signin", "my.1password.com", "wise.com",
                    "venmo.com", "cash.app", "passwords.google.com", "appleid.apple.com", "login.fidelity.com"] {
            XCTAssertEqual(try? OpenWebsiteTool.resolve(bad, deniedApps: denied).get(), nil, bad)
        }
        XCTAssertNotNil(ok("likewise.com", denied), "only a whole part of the name counts")
        XCTAssertNotNil(ok("google.com", denied))
    }
}

@MainActor
final class OpenWebsiteToolTests: XCTestCase {
    var opened: [URL] = []
    var dispatcher: ToolDispatcher!
    var asked: [String] = []
    var answer = true
    var logURL: URL!

    override func setUp() async throws {
        opened = []; asked = []; answer = true
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        let notch = NotchViewModel()
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID()).log")
        dispatcher = ToolDispatcher(config: config, context: ToolContext(config: config, modes: ModeManager(config: config, notch: notch), undo: UndoStack(), notch: notch), log: ActionLog(url: logURL))
        dispatcher.register(OpenWebsiteTool(open: { [unowned self] url in self.opened.append(url); return true }))
        dispatcher.approvalHandler = { [unowned self] r in self.asked.append(r.preview); return self.answer }
    }
    override func tearDown() { try? FileManager.default.removeItem(at: logURL) }

    func testOpensTheSite() async {
        let r = await dispatcher.call("open_website", input: ["site": "youtube.com"], source: .user)
        XCTAssertFalse(r.isError, r.content)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://youtube.com"])
        XCTAssertTrue(asked.isEmpty)
    }

    func testTheRealDenylistBlocksBankSites() async {
        let r = await dispatcher.call("open_website", input: ["site": "https://www.wellsfargo.com"], source: .user)
        XCTAssertTrue(r.isError && r.content.contains("banking"), r.content)
        XCTAssertTrue(opened.isEmpty)
    }

    func testNothingOpensWithoutALiveRequestOrAfterOutsideContentWithoutAYes() async {
        var r = await dispatcher.call("open_website", input: ["site": "example.com"], source: .proactive)
        XCTAssertTrue(r.isError)
        let trace = RequestTrace(source: "text", sink: TraceSink(file: nil))
        trace.markUntrusted("a web page")
        answer = false
        r = await RequestTrace.$current.withValue(trace) { await dispatcher.call("open_website", input: ["site": "evil.example.com/?d=whatever"], source: .user) }
        XCTAssertTrue(r.isError)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(asked, ["Open https://evil.example.com/?d=whatever in the browser. Note: I read a web page before asking this"])
    }
}

final class StayAwakeTests: XCTestCase {
    func testOnlyWhileSwitchedOnAndPluggedIn() {
        XCTAssertTrue(StayAwake.shouldHold(enabled: true, onBattery: false))
        XCTAssertFalse(StayAwake.shouldHold(enabled: true, onBattery: true))
        XCTAssertFalse(StayAwake.shouldHold(enabled: false, onBattery: false))
    }
}

final class LightColorTests: XCTestCase {
    func testNamesAndHex() {
        XCTAssertEqual(LightColor.parse("Red"), 0xFF0000)
        XCTAssertEqual(LightColor.parse(" warm white "), 0xFFD6A5)
        XCTAssertEqual(LightColor.parse("#ff8800"), 0xFF8800)
        XCTAssertEqual(LightColor.parse("00FF00"), 0x00FF00)
        XCTAssertNil(LightColor.parse("sparkly"))
        XCTAssertNil(LightColor.parse("#fff"))
    }
}

/// A pretend Govee: answers the device list from the documented shape and records every control call.
final class FakeGovee: @unchecked Sendable {
    var requests: [(path: String, key: String?, body: JSONObject?)] = []
    var status = 200
    let lock = NSLock()
    static let list = """
    {"code":200,"message":"success","data":[
     {"sku":"H6601","device":"9D:FA","deviceName":"Desk Strip","capabilities":[{"type":"devices.capabilities.on_off","instance":"powerSwitch"},{"type":"devices.capabilities.range","instance":"brightness"},{"type":"devices.capabilities.color_setting","instance":"colorRgb"},{"type":"devices.capabilities.color_setting","instance":"colorTemperatureK"}]},
     {"sku":"H6008","device":"AA:BB","deviceName":"Bedroom Lamp","capabilities":[{"type":"devices.capabilities.on_off","instance":"powerSwitch"},{"type":"devices.capabilities.range","instance":"brightness"}]},
     {"sku":"H7131","device":"CC:DD","deviceName":"Heater","capabilities":[{"type":"devices.capabilities.on_off","instance":"powerSwitch"},{"type":"devices.capabilities.temperature_setting","instance":"targetTemperature"}]}
    ]}
    """
    func client(key: String? = "test-govee-key") -> GoveeClient {
        GoveeClient(key: { key }, transport: { [self] req in
            let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSONObject
            lock.withLock { requests.append((req.url!.path, req.value(forHTTPHeaderField: "Govee-API-Key"), body)) }
            XCTAssertEqual(req.url?.host, "openapi.api.govee.com"); XCTAssertEqual(req.url?.scheme, "https")
            if status != 200 { return (Data("{\"message\":\"nope\"}".utf8), status) }
            return (Data((req.httpMethod == "GET" ? Self.list : "{\"code\":200,\"msg\":\"success\"}").utf8), 200)
        })
    }
    var controls: [String] {
        requests.compactMap { r in
            guard let p = r.body?["payload"] as? JSONObject, let c = p["capability"] as? JSONObject else { return nil }
            return "\(p.string("device") ?? "?") \(c.string("instance") ?? "?")=\(c.int("value") ?? -1)"
        }
    }
}

@MainActor
final class LightsToolTests: XCTestCase {
    var fake: FakeGovee!
    var dispatcher: ToolDispatcher!
    var logURL: URL!

    func make(key: String? = "test-govee-key") {
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        let notch = NotchViewModel()
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID()).log")
        dispatcher = ToolDispatcher(config: config, context: ToolContext(config: config, modes: ModeManager(config: config, notch: notch), undo: UndoStack(), notch: notch), log: ActionLog(url: logURL))
        dispatcher.register(LightsTool(govee: fake.client(key: key)))
    }
    override func setUp() async throws { fake = FakeGovee(); make() }
    override func tearDown() { try? FileManager.default.removeItem(at: logURL) }
    func call(_ input: JSONObject) async -> ToolResult { await dispatcher.call("lights", input: input, source: .user) }

    func testListNamesOnlyLights() async {
        let r = await call(["action": "list"])
        XCTAssertEqual(r.content, "Lights: Desk Strip, Bedroom Lamp.")
        XCTAssertEqual(fake.requests.first?.path, "/router/api/v1/user/devices")
        XCTAssertEqual(fake.requests.first?.key, "test-govee-key")
    }

    func testColourOnOneLightTurnsItOnFirst() async {
        let r = await call(["action": "color", "light": "desk", "color": "blue"])
        XCTAssertFalse(r.isError, r.content)
        XCTAssertEqual(fake.controls, ["9D:FA powerSwitch=1", "9D:FA colorRgb=255"])
        XCTAssertEqual(r.summary, "Desk Strip set to blue.")
    }

    func testOffForEverythingNeverTouchesTheHeater() async {
        let r = await call(["action": "off"])
        XCTAssertEqual(fake.controls, ["9D:FA powerSwitch=0", "AA:BB powerSwitch=0"])
        XCTAssertEqual(r.summary, "All lights turned off.")
    }

    func testALightThatCannotDoColourIsReportedNotFaked() async {
        let r = await call(["action": "color", "color": "red"])
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.content.contains("Desk Strip set to red."), r.content)
        XCTAssertTrue(r.content.contains("Bedroom Lamp can't do that"), r.content)
    }

    func testBrightnessIsClampedAndUnknownNamesAreAsked() async {
        _ = await call(["action": "brightness", "light": "lamp", "brightness": 500])
        XCTAssertEqual(fake.controls.last, "AA:BB brightness=100")
        let r = await call(["action": "on", "light": "kitchen"])
        XCTAssertTrue(r.isError && r.content.contains("Desk Strip, Bedroom Lamp"), r.content)
    }

    func testNoKeyAndBadKeyAreSaidPlainly() async {
        make(key: nil)
        var r = await call(["action": "on"])
        XCTAssertTrue(r.isError && r.content.contains("Govee isn't connected"), r.content)
        XCTAssertTrue(fake.requests.isEmpty)
        fake.status = 401; make()
        r = await call(["action": "on"])
        XCTAssertTrue(r.isError && r.content.contains("refused the API key"), r.content)
    }
}
