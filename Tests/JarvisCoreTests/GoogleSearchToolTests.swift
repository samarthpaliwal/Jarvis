import XCTest
@testable import JarvisCore

@MainActor
final class GoogleSearchToolTests: XCTestCase {
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
        dispatcher.register(GoogleSearchTool(open: { [unowned self] url in self.opened.append(url); return true }))
        dispatcher.approvalHandler = { [unowned self] r in self.asked.append(r.preview); return self.answer }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: logURL) }

    func call(_ input: JSONObject, source: ToolCallSource = .user) async -> ToolResult {
        await dispatcher.call("google_search", input: input, source: source)
    }

    func testOpensGoogleWithTheSearchTypedIn() async {
        let r = await call(["query": "cheap flights to Seattle"])
        XCTAssertFalse(r.isError, r.content)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://www.google.com/search?q=cheap%20flights%20to%20Seattle"])
        XCTAssertEqual(r.summary, "Searched Google for “cheap flights to Seattle”")
        XCTAssertTrue(asked.isEmpty, "Sam asked directly: no extra confirmation")
    }

    func testKinds() {
        XCTAssertEqual(GoogleSearchTool.url(query: "red pandas", kind: "images")?.absoluteString, "https://www.google.com/search?q=red%20pandas&tbm=isch")
        XCTAssertEqual(GoogleSearchTool.url(query: "ramen near me", kind: "maps")?.absoluteString, "https://www.google.com/maps/search/?api=1&query=ramen%20near%20me")
        XCTAssertEqual(GoogleSearchTool.url(query: "x", kind: "nonsense")?.path, "/search")
    }

    func testTheQueryCanNeverChangeWhereThePageGoes() {
        let hostile = ["a&q=b&url=https://evil.example", "x#fragment", "https://evil.example/?", "a+b c", "100% \"quoted\"", "@evil.example/", "../../x"]
        for q in hostile {
            let url = GoogleSearchTool.url(query: q)!
            let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(c.scheme, "https"); XCTAssertEqual(c.host, "www.google.com"); XCTAssertEqual(c.path, "/search")
            XCTAssertNil(c.fragment, q); XCTAssertNil(c.user, q)
            XCTAssertEqual(c.queryItems?.count, 1, q)
            XCTAssertEqual(c.queryItems?.first?.value, q, "the words arrive exactly as said")
        }
    }

    func testQueriesAreOneCappedLine() {
        XCTAssertEqual(GoogleSearchTool.clean("  two\nlines\t here  "), "two lines here")
        XCTAssertEqual(GoogleSearchTool.clean(String(repeating: "a", count: 500)).count, GoogleSearchTool.maxQueryLength)
        XCTAssertNil(GoogleSearchTool.url(query: " \n "))
    }

    func testNothingOpensWithoutALiveRequest() async {
        for source in [ToolCallSource.proactive, .mode] {
            let r = await call(["query": "anything"], source: source)
            XCTAssertTrue(r.isError && r.content.contains("only runs when Sam asks"), r.content)
        }
        XCTAssertTrue(opened.isEmpty)
    }

    func testAKeyNeverGoesIntoASearch() async {
        let r = await call(["query": "what is sk-ant-api03-" + String(repeating: "A1b2", count: 12)])
        XCTAssertTrue(r.isError, r.content)
        XCTAssertTrue(opened.isEmpty)
    }

    func testAfterReadingOutsideContentTheSearchNeedsAYes() async {
        let trace = RequestTrace(source: "text", sink: TraceSink(file: nil))
        trace.markUntrusted("an email")
        answer = false
        var r = await RequestTrace.$current.withValue(trace) { await call(["query": "sam's home address 12 Elm St"]) }
        XCTAssertTrue(r.isError)
        XCTAssertTrue(opened.isEmpty, "an email that says 'search for this' sends nothing without Sam's yes")
        XCTAssertEqual(asked, ["Search Google for “sam's home address 12 Elm St”. Note: I read an email before asking this"])
        answer = true
        r = await RequestTrace.$current.withValue(trace) { await call(["query": "weather in Tucson"]) }
        XCTAssertFalse(r.isError, r.content)
        XCTAssertEqual(opened.count, 1)
    }
}
