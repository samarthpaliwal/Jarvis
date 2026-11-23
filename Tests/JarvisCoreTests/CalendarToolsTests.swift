import XCTest
@testable import JarvisCore

final class FakeCalendar: CalendarProviding, @unchecked Sendable {
    typealias Item = CalendarService.Item
    var items: [Item] = []
    private var next = 1

    func add(_ title: String, hour: Int, minutes: Int = 60, day: Int = 0, recurring: Bool = false, attendees: Int = 0, editable: Bool = true) -> Item {
        let base = Calendar.current.date(byAdding: .day, value: day, to: Calendar.current.startOfDay(for: Date()))!
        let start = base.addingTimeInterval(Double(hour) * 3600)
        let item = Item(id: "evt-\(next)", title: title, start: start, end: start.addingTimeInterval(Double(minutes) * 60), isAllDay: false,
                        location: nil, calendar: editable ? "Home" : "US Holidays", notes: nil, isReminder: false,
                        isRecurring: recurring, attendees: attendees, editable: editable)
        next += 1
        items.append(item)
        return item
    }

    func events(from: Date, to: Date) async throws -> [Item] { items.filter { ($0.start ?? .distantPast) >= from && ($0.start ?? .distantPast) < to }.sorted { $0.start! < $1.start! } }
    func incompleteReminders(dueBefore: Date?) async throws -> [Item] { [] }
    func createEvent(title: String, start: Date, end: Date, location: String?, notes: String?, allDay: Bool) async throws -> Item {
        let item = Item(id: "evt-\(next)", title: title, start: start, end: end, isAllDay: allDay, location: location, calendar: "Home", notes: notes, isReminder: false)
        next += 1; items.append(item); return item
    }
    func moveEvent(_ item: Item, start: Date, end: Date) async throws -> Item {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { throw CalendarService.CalendarError.notFound(item.title) }
        items[i].start = start; items[i].end = end
        return items[i]
    }
    func cancelEvent(_ item: Item) async throws {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { throw CalendarService.CalendarError.notFound(item.title) }
        items.remove(at: i)
    }
    func deleteEvent(id: String) throws { items.removeAll { $0.id == id } }
    func createReminder(title: String, due: Date?, notes: String?) async throws -> Item { throw CalendarService.CalendarError.denied("Reminders") }
    func deleteReminder(id: String) throws {}
}

final class CalendarMatcherTests: XCTestCase {
    func items(_ titles: [(String, Int)]) -> [CalendarService.Item] {
        let cal = FakeCalendar()
        return titles.map { cal.add($0.0, hour: $0.1) }
    }

    func testFindsTheEventFromAFewSpokenWords() {
        let day = items([("CSC 120 Lecture", 9), ("MATH 129 Calculus II", 11), ("Gym", 6)])
        func title(_ q: String) -> String? { if case .success(let i) = CalendarMatcher.resolve(title: q, in: day) { return i.title }; return nil }
        XCTAssertEqual(title("calculus"), "MATH 129 Calculus II")
        XCTAssertEqual(title("my calculus class"), "MATH 129 Calculus II", "filler words are ignored")
        XCTAssertEqual(title("csc 120"), "CSC 120 Lecture")
        XCTAssertEqual(title("the gym"), "Gym")
        XCTAssertEqual(title("calc"), "MATH 129 Calculus II", "a prefix is enough")
    }

    func testAmbiguousAndMissingAreReportedNotGuessed() {
        let day = items([("Study group", 14), ("Study group", 19), ("Dinner", 18)])
        XCTAssertEqual(CalendarMatcher.resolve(title: "study group", in: day), .failure(.several(day.prefix(2).map(describe))))
        if case .failure(.none(let onDay)) = CalendarMatcher.resolve(title: "dentist", in: day) { XCTAssertEqual(onDay.count, 3) } else { XCTFail() }
        // The start time picks one of two.
        if case .success(let i) = CalendarMatcher.resolve(title: "study group", at: day[1].start, in: day) { XCTAssertEqual(i.id, day[1].id) } else { XCTFail() }
        XCTAssertTrue(CalendarMatcher.explain(.several(["a", "b"]), title: "study group", day: "today").contains("Ask which one"))
    }
}

@MainActor
final class CalendarToolsTests: XCTestCase {
    var cal: FakeCalendar!
    var dispatcher: ToolDispatcher!
    var undo: UndoStack!
    var asked: [String] = []
    var answer = true
    var logURL: URL!

    override func setUp() async throws {
        cal = FakeCalendar()
        undo = UndoStack()
        asked = []; answer = true
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        let notch = NotchViewModel()
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID()).log")
        dispatcher = ToolDispatcher(config: config, context: ToolContext(config: config, modes: ModeManager(config: config, notch: notch), undo: undo, notch: notch), log: ActionLog(url: logURL))
        dispatcher.register([CalendarReadTool(calendar: cal), CalendarCreateTool(calendar: cal), CalendarMoveTool(calendar: cal), CalendarCancelTool(calendar: cal)])
        dispatcher.approvalHandler = { [unowned self] request in self.asked.append(request.preview); return self.answer }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: logURL) }

    func hour(_ item: CalendarService.Item?) -> Int { Calendar.current.component(.hour, from: item?.start ?? .distantPast) }

    // MARK: List

    func testListShowsWhatMattersForChangingAnEvent() async {
        _ = cal.add("Calculus", hour: 23, recurring: true)
        _ = cal.add("Team sync", hour: 23, minutes: 30, attendees: 3)
        let r = await dispatcher.call("calendar_read", input: ["date": "today", "include_reminders": false], source: .user)
        XCTAssertTrue(r.content.contains("Calculus") && r.content.contains("(repeats)"), r.content)
        XCTAssertTrue(r.content.contains("3 invited"), r.content)
    }

    // MARK: Move

    func testMoveKeepsTheLengthAndCanBeUndone() async throws {
        let e = cal.add("Calculus", hour: 9, minutes: 50)
        let r = await dispatcher.call("calendar_move", input: ["title": "calculus", "date": "today", "new_start": "today 3pm"], source: .user)
        XCTAssertFalse(r.isError, r.content)
        XCTAssertEqual(hour(cal.items.first), 15)
        XCTAssertEqual(cal.items[0].end!.timeIntervalSince(cal.items[0].start!), 50 * 60, "still 50 minutes long")
        XCTAssertTrue(asked.isEmpty, "a move with nobody else invited is reversible, so it needs no approval")
        XCTAssertEqual(r.summary?.hasPrefix("Moved “Calculus” to"), true)

        let undone = try await undo.undoLast()
        XCTAssertTrue(undone.contains("back"))
        XCTAssertEqual(cal.items[0].start, e.start)
    }

    func testMovingAnEventWithInvitedPeopleAsksFirst() async {
        _ = cal.add("Team sync", hour: 10, attendees: 3)
        answer = false
        var r = await dispatcher.call("calendar_move", input: ["title": "team sync", "new_start": "today 4pm"], source: .user)
        XCTAssertTrue(r.isError)
        XCTAssertEqual(hour(cal.items.first), 10, "denied: nothing moved")
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].contains("“Team sync”") && asked[0].contains("3 other people are invited"), asked[0])

        answer = true
        r = await dispatcher.call("calendar_move", input: ["title": "team sync", "new_start": "today 4pm"], source: .user)
        XCTAssertFalse(r.isError, r.content)
        XCTAssertEqual(hour(cal.items.first), 16)
    }

    func testAProactiveFeatureCanNeverNotifyOtherPeople() async {
        _ = cal.add("Team sync", hour: 10, attendees: 2)
        let r = await dispatcher.call("calendar_move", input: ["title": "team sync", "new_start": "today 4pm"], source: .proactive)
        XCTAssertTrue(r.isError)
        XCTAssertEqual(hour(cal.items.first), 10)
        XCTAssertTrue(asked.isEmpty, "no approval prompt may come from a non-user source")
    }

    func testReadOnlyAndUnclearEventsAreNotTouched() async {
        _ = cal.add("Thanksgiving", hour: 0, editable: false)
        _ = cal.add("Study group", hour: 14)
        _ = cal.add("Study group", hour: 19)
        var r = await dispatcher.call("calendar_move", input: ["title": "thanksgiving", "new_start": "tomorrow 9am"], source: .user)
        XCTAssertTrue(r.isError && r.content.contains("read-only"), r.content)
        r = await dispatcher.call("calendar_move", input: ["title": "study group", "new_start": "tomorrow 9am"], source: .user)
        XCTAssertTrue(r.isError && r.content.contains("More than one event"), r.content)
        r = await dispatcher.call("calendar_move", input: ["title": "study group", "at": "7pm", "new_start": "today 8pm"], source: .user)
        XCTAssertFalse(r.isError, r.content)
        XCTAssertEqual(cal.items.filter { $0.title == "Study group" }.map(hour).sorted(), [14, 20])
        r = await dispatcher.call("calendar_move", input: ["title": "dentist", "new_start": "tomorrow 9am"], source: .user)
        XCTAssertTrue(r.isError && r.content.contains("No event matching"), r.content)
    }

    // MARK: Cancel

    func testCancelAlwaysAsksAndNamesTheRealEvent() async {
        _ = cal.add("MATH 129 Calculus II", hour: 9, recurring: true)
        answer = false
        var r = await dispatcher.call("calendar_cancel", input: ["title": "calculus"], source: .user)
        XCTAssertTrue(r.isError)
        XCTAssertEqual(cal.items.count, 1, "no approval, no deletion")
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].hasPrefix("Cancel “MATH 129 Calculus II” on "), "the prompt names the event that would be deleted: \(asked[0])")
        XCTAssertTrue(asked[0].contains("this occurrence only"))

        answer = true
        r = await dispatcher.call("calendar_cancel", input: ["title": "calculus"], source: .user)
        XCTAssertFalse(r.isError, r.content)
        XCTAssertTrue(cal.items.isEmpty)
    }

    func testCancelCanBeUndone() async throws {
        let e = cal.add("Dentist", hour: 13)
        _ = await dispatcher.call("calendar_cancel", input: ["title": "dentist"], source: .user)
        XCTAssertTrue(cal.items.isEmpty)
        _ = try await undo.undoLast()
        XCTAssertEqual(cal.items.count, 1)
        XCTAssertEqual(cal.items[0].title, "Dentist")
        XCTAssertEqual(cal.items[0].start, e.start)
    }

    func testCancelCannotBeTriggeredWithoutAUserTurn() async {
        _ = cal.add("Dentist", hour: 13)
        let r = await dispatcher.call("calendar_cancel", input: ["title": "dentist"], source: .proactive)
        XCTAssertTrue(r.isError)
        XCTAssertEqual(cal.items.count, 1)
        XCTAssertTrue(asked.isEmpty)
    }

    func testCreateThenMoveThenCancelRoundTrip() async {
        var r = await dispatcher.call("calendar_create", input: ["title": "Office hours", "start": "tomorrow 2pm"], source: .user)
        XCTAssertFalse(r.isError, r.content)
        r = await dispatcher.call("calendar_move", input: ["title": "office hours", "date": "tomorrow", "new_start": "tomorrow 4pm"], source: .user)
        XCTAssertFalse(r.isError, r.content)
        XCTAssertEqual(hour(cal.items.first), 16)
        r = await dispatcher.call("calendar_cancel", input: ["title": "office hours", "date": "tomorrow"], source: .user)
        XCTAssertFalse(r.isError, r.content)
        XCTAssertTrue(cal.items.isEmpty)
    }
}
