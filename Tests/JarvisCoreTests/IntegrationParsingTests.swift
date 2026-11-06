import XCTest
@testable import JarvisCore

final class NotionParsingTests: XCTestCase {
    func testParsesHomeworkRow() {
        let row: JSONObject = [
            "id": "abc", "url": "https://notion.so/abc",
            "properties": [
                "Assignment": ["type": "title", "title": [["plain_text": "Problem set 4"]]],
                "Due": ["type": "date", "date": ["start": "2026-11-09"]],
                "Status": ["type": "select", "select": ["name": "In progress"]],
                "Class": ["type": "relation", "relation": [["id": "cls1"]]],
                "Priority": ["type": "select", "select": ["name": "High"]],
            ],
        ]
        let p = NotionClient.parsePage(row)
        XCTAssertEqual(p.title, "Problem set 4")
        XCTAssertEqual(p.status, "In progress")
        XCTAssertEqual(p.relationIDs, ["cls1"])
        XCTAssertEqual(p.extra["Priority"], "High")
        XCTAssertEqual(p.date.map { NotionClient.dateString($0) }, "2026-11-09")
    }

    func testLenientNotionConfigDecoding() throws {
        let old = #"{"tasksDatabaseId":"x","examsDatabaseId":"y"}"#
        let n = try JSONDecoder().decode(Profile.Notion.self, from: Data(old.utf8))
        XCTAssertEqual(n.homeworkDueProperty, "Due")
        XCTAssertEqual(n.homeworkDoneValues, ["Submitted", "Graded"])
        XCTAssertEqual(n.homeworkDataSourceId, "")
    }
}

final class GmailParsingTests: XCTestCase {
    func testBase64URLRoundTrip() {
        let s = "héllo? & bye/plus+"
        let enc = Data(s.utf8).base64URL()
        XCTAssertFalse(enc.contains("+") || enc.contains("/") || enc.contains("="))
        XCTAssertEqual(String(data: Data(base64URL: enc)!, encoding: .utf8), s)
    }

    func testParsesMultipartMessagePreferringPlainText() {
        let obj: JSONObject = [
            "id": "m1", "threadId": "t1", "snippet": "snip", "labelIds": ["INBOX"],
            "payload": [
                "mimeType": "multipart/alternative",
                "headers": [["name": "From", "value": "Prof <p@arizona.edu>"], ["name": "Subject", "value": "Exam 2 next week"]],
                "parts": [
                    ["mimeType": "text/html", "body": ["data": Data("<p>Hi <b>Sam</b></p>".utf8).base64URL()]],
                    ["mimeType": "text/plain", "body": ["data": Data("Hi Sam".utf8).base64URL()]],
                ],
            ],
        ]
        let m = GmailClient.parse(obj)
        XCTAssertEqual(m.subject, "Exam 2 next week")
        XCTAssertEqual(m.from, "Prof <p@arizona.edu>")
        XCTAssertEqual(m.body, "Hi Sam")
        XCTAssertEqual(GmailClient.stripHTML("<div>Hello<br>there &amp; <script>x()</script>you</div>"), "Hello\nthere & you")
    }
}

final class DateParsingTests: XCTestCase {
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 10, minute: 0))!

    func testRelativeAndAbsoluteForms() {
        XCTAssertEqual(DateParsing.parse("in 20 minutes", now: now), now.addingTimeInterval(1200))
        let tomorrow3 = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 15))!
        XCTAssertEqual(DateParsing.parse("tomorrow 3pm", now: now), tomorrow3)
        XCTAssertEqual(DateParsing.parse("tomorrow at 3:30pm", now: now), tomorrow3.addingTimeInterval(1800))
        let fri = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 10))!
        XCTAssertEqual(DateParsing.parse("friday 10am", now: now), fri)
        XCTAssertEqual(DateParsing.parse("2026-11-07 15:00", now: now), Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 15)))
        XCTAssertNil(DateParsing.parse("whenever", now: now))
    }
}

final class BriefingLogicTests: XCTestCase {
    func testSpokenSummaryShapes() {
        let mode = ModesConfig.fallback.modes[0]
        let morning = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 7))!
        let d = BriefingData(tasks: [.init(title: "CSC 210 pset"), .init(title: "Gym")], deadlines: [], exams: [.init(title: "CSC 210 midterm", daysLeft: 6)])
        XCTAssertEqual(BriefingService.spoken(d, name: "Sam", now: morning, nextClass: nil, mode: mode),
                       "Morning, Sam. 2 things today, and your CSC 210 midterm is in 6 days.")
        let empty = BriefingData(tasks: [], deadlines: [.init(title: "Essay", daysLeft: 1)], exams: [])
        XCTAssertEqual(BriefingService.spoken(empty, name: "Sam", now: morning.addingTimeInterval(12 * 3600), nextClass: nil, mode: mode),
                       "Evening, Sam. nothing left today, and next deadline is Essay in 1 day.")
    }

    func testTitleCleaningAndDedupe() {
        XCTAssertEqual(BriefingService.cleanTitle("[CSC120] Midterm 2 Today at 3:00pm"), "CSC120 Midterm 2")
        XCTAssertEqual(BriefingService.cleanTitle("Essay due at 11:59 PM"), "Essay due")
        let d = BriefingService.dedupe([.init(title: "[CSC120] Midterm 2 Today at 3:00pm", daysLeft: 8), .init(title: "[CSC120] Midterm 2", daysLeft: 8)])
        XCTAssertEqual(d.map(\.title), ["CSC120 Midterm 2"])
    }

    func testClassDetection() {
        XCTAssertTrue(BriefingService.looksLikeClass("csc 210 lecture", keywords: []))
        XCTAssertTrue(BriefingService.looksLikeClass("math129 discussion", keywords: ["discussion"]))
        XCTAssertFalse(BriefingService.looksLikeClass("gym", keywords: []))
    }

    func testDaysLeftUsesCalendarDays() {
        let a = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 5))!
        let b = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 23))!
        XCTAssertEqual(BriefingService.days(from: a, to: b), 6)
    }
}

final class LoopbackListenerTests: XCTestCase {
    func testBindsARealLoopbackPortAndReceivesTheCallback() async throws {
        let listener = try LoopbackListener()
        XCTAssertGreaterThan(listener.port, 1024, "redirect URI must carry a real port, never 0")
        async let params = listener.waitForCallback(timeout: 5)
        try await Task.sleep(for: .milliseconds(100))
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        let url = URL(string: "http://127.0.0.1:\(listener.port)/callback?state=s1&code=4%2Fabc")!
        let (data, resp) = try await URLSession(configuration: cfg).data(from: url)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("connected to Gmail"))
        let got = try await params
        XCTAssertEqual(got["code"], "4/abc")
        XCTAssertEqual(got["state"], "s1")
    }
}
