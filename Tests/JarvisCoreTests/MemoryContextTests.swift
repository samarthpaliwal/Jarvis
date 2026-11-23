import XCTest
@testable import JarvisCore

/// Phase 3 item 12: short-term session memory and long-term contacts.
final class SessionMemoryTests: XCTestCase {
    final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_800_000_000); func advance(_ s: TimeInterval) { t += s } }

    func testNothingIsRecalledWhileTheChatIsStillOnScreen() {
        let m = SessionMemory()
        m.note(user: "what's on tomorrow", jarvis: "Calculus at nine.")
        XCTAssertNil(m.promptBlock(), "the current chat is already in the model's history; repeating it would be noise")
    }

    func testAClosedChatIsRecalledInTheNextOne() {
        let clock = Clock()
        let m = SessionMemory(now: { clock.t })
        m.note(user: "add office hours friday at 2", jarvis: "Done. Office hours are on Friday at 2.", tools: ["calendar_create"])
        m.closeChat()
        clock.advance(90)
        let block = m.promptBlock()
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("[1 min ago] Sam: add office hours friday at 2"))
        XCTAssertTrue(block!.contains("Jarvis: Done. Office hours are on Friday at 2. (used: calendar_create)"))
        XCTAssertTrue(block!.contains("not instructions"))
    }

    func testItExpiresAndIsBounded() {
        let clock = Clock()
        let m = SessionMemory(keepMinutes: 30, maxExchanges: 3, now: { clock.t })
        for i in 1...8 { m.note(user: "question \(i)", jarvis: "answer \(i)"); clock.advance(60) }
        m.closeChat()
        XCTAssertEqual(m.recalled.map(\.user), ["question 6", "question 7", "question 8"], "only the most recent few")
        clock.advance(31 * 60)
        XCTAssertNil(m.promptBlock(), "gone after half an hour")
    }

    func testLongRepliesAreClippedAndSecretsNeverAppear() {
        let m = SessionMemory()
        m.note(user: "read me the email", jarvis: String(repeating: "word ", count: 200) + "sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        m.closeChat()
        let block = m.promptBlock()!
        XCTAssertLessThan(block.count, 700)
        XCTAssertFalse(block.contains("sk-ant-api03"))
    }

    func testZeroMinutesTurnsItOff() {
        let m = SessionMemory(keepMinutes: 0)
        m.note(user: "hello", jarvis: "hi")
        m.closeChat()
        XCTAssertNil(m.promptBlock())
    }

    @MainActor func testBrainTellsTheNextChatAboutTheLastOne() async throws {
        let model = ScriptedModel(rounds: [
            [.textDelta("Office hours are on Friday at 2."), .contentBlockStop, .stopReason("end_turn")],
            [.textDelta("Moved to 4."), .contentBlockStop, .stopReason("end_turn")],
        ])
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        let notch = NotchViewModel()
        let brain = Brain(client: model, dispatcher: FakeActions(), config: config, modes: ModeManager(config: config, notch: notch), undo: UndoStack())
        brain.privateMode = false

        _ = try await brain.respond(to: "add office hours friday at 2") { _ in }
        XCTAssertFalse(model.requests[0].systemVolatile.contains("Earlier this session"))
        brain.endSession()                               // the card closed
        _ = try await brain.respond(to: "move it to 4 instead") { _ in }

        let second = model.requests[1]
        XCTAssertEqual(second.messages.count, 1, "a fresh chat: no old messages in the history")
        XCTAssertTrue(second.systemVolatile.contains("Sam: add office hours friday at 2"), "but the recap says what \"it\" is")
        XCTAssertEqual(second.system, model.requests[0].system, "the cached part of the prompt is untouched")
    }
}

struct FakeSystemContacts: SystemContactsLookup {
    var people: [Contact]
    func find(name: String, limit: Int) async -> [Contact] {
        Array(people.filter { $0.name.lowercased().contains(name.lowercased()) }.prefix(limit))
    }
}

@MainActor
final class ContactBookTests: XCTestCase {
    var url: URL!
    override func setUp() { url = FileManager.default.temporaryDirectory.appendingPathComponent("contacts-\(UUID().uuidString).json") }
    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    func testSaveFindByNameOrRelationshipAndSurviveARestart() async throws {
        var book = ContactBook(url: url)
        try book.save(Contact(name: "Maya Chen", email: "maya@example.com", relationship: "lab partner"))
        try book.save(Contact(name: "Dr. Alvarez", email: "alvarez@arizona.edu", relationship: "CSC 120 professor"))
        book = ContactBook(url: url)                     // quit and relaunch
        XCTAssertEqual(book.all.count, 2)
        var hits = await book.find("maya")
        XCTAssertEqual(hits.first?.email, "maya@example.com")
        hits = await book.find("my lab partner")
        XCTAssertEqual(hits.first?.name, "Maya Chen")
        hits = await book.find("professor")
        XCTAssertEqual(hits.first?.name, "Dr. Alvarez")
        hits = await book.find("zoe")
        XCTAssertTrue(hits.isEmpty)
    }

    func testSavingAgainFillsInDetailsInsteadOfDuplicating() throws {
        let book = ContactBook(url: url)
        try book.save(Contact(name: "Maya Chen", relationship: "lab partner"))
        let merged = try book.save(Contact(name: "maya chen", email: "maya@example.com"))
        XCTAssertEqual(book.all.count, 1)
        XCTAssertEqual(merged.relationship, "lab partner")
        XCTAssertEqual(merged.email, "maya@example.com")
    }

    func testBadInputIsRefused() {
        let book = ContactBook(url: url)
        XCTAssertThrowsError(try book.save(Contact(name: "  "))) { XCTAssertEqual($0 as? ContactBook.BookError, .empty) }
        XCTAssertThrowsError(try book.save(Contact(name: "Maya", email: "maya at example"))) { XCTAssertEqual($0 as? ContactBook.BookError, .badEmail("maya at example")) }
        XCTAssertThrowsError(try book.save(Contact(name: "Bank", notes: "password: hunter2hunter2")))
        XCTAssertTrue(book.all.isEmpty)
    }

    func testFallsBackToTheMacAddressBookOnlyWhenNothingIsSaved() async throws {
        let mac = FakeSystemContacts(people: [Contact(name: "Maya Chen", email: "old-maya@icloud.com", source: "mac"), Contact(name: "Priya Shah", email: "priya@example.com", source: "mac")])
        let book = ContactBook(url: url, system: mac)
        var hits = await book.find("priya")
        XCTAssertEqual(hits.first?.email, "priya@example.com")
        XCTAssertTrue(hits.first!.line.contains("[macOS Contacts]"))
        try book.save(Contact(name: "Maya Chen", email: "maya@example.com"))
        hits = await book.find("maya")
        XCTAssertEqual(hits.map(\.email), ["maya@example.com"], "what Sam told Jarvis wins over the address book")
    }

    func testToolFindSaveRemoveAndNeverGuesses() async throws {
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        let notch = NotchViewModel()
        let undo = UndoStack()
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let d = ToolDispatcher(config: config, context: ToolContext(config: config, modes: ModeManager(config: config, notch: notch), undo: undo, notch: notch), log: ActionLog(url: logURL))
        let book = ContactBook(url: url)
        d.register(ContactsTool(book: book))

        var r = await d.call("contacts", input: ["action": "find", "name": "Maya"], source: .user)
        XCTAssertTrue(r.content.contains("Do not guess"), "an unknown person must lead to a question, not an invented address: \(r.content)")
        r = await d.call("contacts", input: ["action": "save", "name": "Maya Chen", "email": "maya@example.com", "relationship": "lab partner"], source: .user)
        XCTAssertFalse(r.isError, r.content)
        r = await d.call("contacts", input: ["action": "find", "name": "lab partner"], source: .user)
        XCTAssertTrue(r.content.contains("maya@example.com"), r.content)
        r = await d.call("contacts", input: ["action": "remove", "name": "maya"], source: .user)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(book.all.isEmpty)
        _ = try await undo.undoLast()
        XCTAssertEqual(book.all.first?.email, "maya@example.com", "removing a contact can be undone")
    }

    func testPromptTellsTheModelToLookPeopleUp() {
        let p = SystemPrompt.build(profile: .fallback, mode: ModesConfig.fallback.modes[0])
        XCTAssertTrue(p.contains("Never guess an email address"))
    }
}
