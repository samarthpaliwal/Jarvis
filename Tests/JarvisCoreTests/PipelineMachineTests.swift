import XCTest
@testable import JarvisCore

final class PipelineMachineTests: XCTestCase {
    typealias M = PipelineMachine

    func testHappyPathVisitsEveryStageInOrder() {
        XCTAssertEqual(M.run(M.happyPath), [.idle, .listening, .thinking, .speaking, .idle])
    }

    func testEveryEventFromEveryStateIsLegalWithItsTargetOrRefused() {
        for event in PipelineEvent.allCases {
            XCTAssertFalse(event.allowedFrom.isEmpty, "\(event) can never happen")
            for state in PipelineState.allCases {
                let next = M.next(state, on: event)
                if event.allowedFrom.contains(state) { XCTAssertEqual(next, event.target) }
                else { XCTAssertNil(next, "\(event) must be refused while \(state)") }
            }
        }
    }

    func testEveryStateIsReachableAndCanGetBackToIdle() {
        var reachable: Set<PipelineState> = [.idle]
        var grew = true
        while grew {
            grew = false
            for s in reachable { for e in PipelineEvent.allCases { if let n = M.next(s, on: e), reachable.insert(n).inserted { grew = true } } }
        }
        XCTAssertEqual(reachable, Set(PipelineState.allCases))
        for s in PipelineState.allCases { XCTAssertEqual(M.next(s, on: .stopped), .idle, "stop must work from \(s)") }
    }

    func testRealFlows() {
        // Wake, then nothing said.
        XCTAssertEqual(M.run([.wake, .noSpeech]), [.idle, .listening, .idle])
        // Reply, follow-up without the wake word, "thanks".
        XCTAssertEqual(M.run(M.happyPath + [.followUp, .conversationEnded])?.last, .idle)
        // Talking over the reply starts a new listen.
        XCTAssertEqual(M.run([.wake, .transcribed, .replyStarted, .bargeIn, .transcribed, .replyStarted, .replyFinished])?.last, .idle)
        // A Tier 2 tool mid-reply: approve, keep talking.
        XCTAssertEqual(M.run([.wake, .transcribed, .replyStarted, .approvalNeeded, .approvalResolved, .replyStarted, .replyFinished]),
                       [.idle, .listening, .thinking, .speaking, .awaitingApproval, .thinking, .speaking, .idle])
        // Voice off: shown, never spoken.
        XCTAssertEqual(M.run([.typed, .replyFinished]), [.idle, .thinking, .idle])
        // The microphone heard Jarvis.
        XCTAssertEqual(M.run(M.happyPath + [.followUp, .echoDiscarded])?.last, .idle)
        // A briefing outside any request.
        XCTAssertEqual(M.run([.announce, .replyFinished]), [.idle, .speaking, .idle])
    }

    func testThingsThatMustNeverHappen() {
        XCTAssertNil(M.next(.idle, on: .transcribed), "no transcript without listening")
        XCTAssertNil(M.next(.idle, on: .replyStarted), "no reply without a request")
        XCTAssertNil(M.next(.thinking, on: .wake), "a wake word must not restart a request that is being answered")
        XCTAssertNil(M.next(.awaitingApproval, on: .wake), "the wake word must not skip an approval")
        XCTAssertNil(M.next(.awaitingApproval, on: .replyStarted), "nothing is spoken as a reply until the approval is resolved")
        XCTAssertNil(M.next(.thinking, on: .approvalResolved), "an approval cannot be resolved twice")
        XCTAssertNil(M.next(.listening, on: .followUp))
        XCTAssertNil(M.next(.thinking, on: .announce), "announcements wait for idle")
        XCTAssertNil(M.run([.wake, .replyStarted]))
    }
}
