import XCTest
@testable import JarvisCore

/// Phase 2 item 6: the three latency fixes.
final class LatencyTests: XCTestCase {
    // MARK: First audio sooner

    func chunks(_ text: String, minWords: Int) -> [String] {
        var c = SentenceChunker(firstChunkMinWords: minWords)
        var out: [String] = []
        // Feed a few characters at a time, the way the model streams.
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: 5, limitedBy: text.endIndex) ?? text.endIndex
            out += c.push(String(text[i..<j]))
            i = j
        }
        if let rest = c.flush() { out.append(rest) }
        return out
    }

    func testOpeningClauseIsSpokenBeforeTheSentenceEnds() {
        let text = "Good morning, Sam, it's seven o'clock on a Monday, you have two classes today, and the weather is clear. Calculus is first."
        XCTAssertEqual(chunks(text, minWords: 3),
                       ["Good morning, Sam,", "it's seven o'clock on a Monday, you have two classes today, and the weather is clear.", "Calculus is first."])
        XCTAssertEqual(chunks(text, minWords: 0).first, "Good morning, Sam, it's seven o'clock on a Monday, you have two classes today, and the weather is clear.",
                       "0 keeps the old whole-sentence behaviour")
    }

    func testOnlyTheFirstChunkIsSplitAndNothingIsLostOrReordered() {
        let text = "The Wildcats play Utah next, hosting them on Saturday. After that, they travel to Tempe, which is the rivalry game."
        let out = chunks(text, minWords: 3)
        XCTAssertEqual(out, ["The Wildcats play Utah next,", "hosting them on Saturday.", "After that, they travel to Tempe, which is the rivalry game."])
        XCTAssertEqual(out.joined(separator: " "), text)
    }

    func testNumbersTimesAndShortOpenersAreNotSplit() {
        XCTAssertEqual(chunks("It costs 1,000 dollars and opens at 9:30 tomorrow.", minWords: 3), ["It costs 1,000 dollars and opens at 9:30 tomorrow."])
        XCTAssertEqual(chunks("Yes, it is.", minWords: 3), ["Yes, it is."], "a one-word opener is not worth its own audio clip")
        XCTAssertEqual(chunks("Checking now. Your first event is at nine, in Gould-Simpson.", minWords: 3),
                       ["Checking now.", "Your first event is at nine, in Gould-Simpson."], "a short first sentence is already a fast first chunk")
    }

    /// Found by the benchmark: a sentence ending in a two-letter word used to stall the whole reply.
    func testSentencesEndingInShortWordsStillSplit() {
        let text = "That doesn't map to anything I can act on. I can adjust the volume for you if you want it. Just say so. Shall I do it?"
        XCTAssertEqual(chunks(text, minWords: 0), ["That doesn't map to anything I can act on.", "I can adjust the volume for you if you want it.", "Just say so.", "Shall I do it?"])
        XCTAssertEqual(chunks("Battery is at 76. Charging now.", minWords: 0), ["Battery is at 76.", "Charging now."])
        XCTAssertEqual(chunks("I said no. Then I left.", minWords: 0), ["I said no.", "Then I left."])
    }

    func testRealAbbreviationsDoNotSplit() {
        XCTAssertEqual(chunks("Dr. Lee moved it to 9 a.m. tomorrow in the U.S. office. Bring a laptop.", minWords: 0),
                       ["Dr. Lee moved it to 9 a.m. tomorrow in the U.S. office.", "Bring a laptop."])
        XCTAssertEqual(chunks("Use a short query, e.g. play jazz. That works.", minWords: 0), ["Use a short query, e.g. play jazz.", "That works."])
        XCTAssertEqual(chunks("They are ranked No. 3 this week. Kickoff is at 3.5 hours from now.", minWords: 0),
                       ["They are ranked No. 3 this week.", "Kickoff is at 3.5 hours from now."])
        XCTAssertEqual(chunks("First item. 2. The essay. 3. Laundry.", minWords: 0), ["First item.", "2. The essay.", "3. Laundry."],
                       "a list number at the start of an item stays with its item")
    }

    // MARK: Shorter silence wait

    func endReason(_ transcript: String, silence: TimeInterval, fast: TimeInterval? = 0.9) -> Endpointer.Reason? {
        var settings = Endpointer.Settings()
        settings.silenceAfterSpeech = 1.3
        settings.silenceAfterSentence = fast
        let t0 = Date(timeIntervalSince1970: 1_000)
        var e = Endpointer(settings: settings, now: t0)
        e.update(TranscriptUpdate(text: transcript, isFinal: false), at: t0.addingTimeInterval(2))
        return e.shouldEnd(at: t0.addingTimeInterval(2 + silence))
    }

    func testFinishedSentenceEndsAfterShortSilence() {
        XCTAssertEqual(endReason("What time is my first event tomorrow?", silence: 1.0), .silenceAfterSpeech)
        XCTAssertNil(endReason("What time is my first event tomorrow?", silence: 0.8), "still waits the fast silence")
    }

    func testUnfinishedSentenceStillGetsTheFullWait() {
        XCTAssertNil(endReason("Please check the", silence: 1.0), "no end punctuation: he may be mid-thought")
        XCTAssertEqual(endReason("Please check the", silence: 1.4), .silenceAfterSpeech)
        XCTAssertNil(endReason("Play.", silence: 1.0), "one word is not a finished request")
    }

    func testFastSilenceCanBeTurnedOff() {
        XCTAssertNil(endReason("What time is it right now?", silence: 1.0, fast: 0))
        XCTAssertNil(endReason("What time is it right now?", silence: 1.0, fast: nil))
        XCTAssertNil(endReason("What time is it right now?", silence: 1.0, fast: 2.0), "a 'fast' value slower than the normal one is ignored")
    }

    // MARK: Cache pre-warm

    func testPrewarmBodyMatchesARealRequestAndGeneratesNothing() {
        let client = ClaudeClient()
        var r = ClaudeClient.Request(model: "claude-sonnet-5-5", system: "stable rules", messages: [["role": "user", "content": "hi"]],
                                     tools: [["name": "music", "description": "d", "input_schema": ["type": "object"]]], maxTokens: 1024, effort: "low")
        r.systemVolatile = "now: 7am"
        let real = client.body(for: r), warm = client.prewarmBody(for: r)
        XCTAssertEqual(warm["max_tokens"] as? Int, 0)
        XCTAssertEqual(warm["stream"] as? Bool, false, "max_tokens 0 is rejected with stream: true")
        // Everything that is part of the cached prefix must be byte-identical.
        for key in ["model", "tools", "output_config", "thinking"] {
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: [key: real[key] as Any], options: .sortedKeys),
                           try JSONSerialization.data(withJSONObject: [key: warm[key] as Any], options: .sortedKeys), key)
        }
        let realSystem = real["system"] as? [JSONObject], warmSystem = warm["system"] as? [JSONObject]
        XCTAssertEqual(realSystem?.first?["text"] as? String, warmSystem?.first?["text"] as? String)
        XCTAssertNotNil(warmSystem?.first?["cache_control"])
    }

    @MainActor func testPrewarmFiresOnlyWhenTheCacheIsCold() async throws {
        let model = ScriptedModel(rounds: [[.textDelta("Hello."), .contentBlockStop, .stopReason("end_turn")]])
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        let notch = NotchViewModel()
        let brain = Brain(client: model, dispatcher: FakeActions(), config: config, modes: ModeManager(config: config, notch: notch), undo: UndoStack())
        brain.privateMode = false

        brain.prewarmIfCold()
        brain.prewarmIfCold()                      // a second word arriving must not send a second request
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.prewarms.count, 1)
        XCTAssertEqual(model.prewarms[0].effort, config.tuning.llmEffort, "same effort as real turns, or the entry is never hit")
        XCTAssertEqual(model.prewarms[0].tools.count, 3, "web search, web fetch, and the tool: the same list a real turn sends")

        _ = try await brain.respond(to: "hello") { _ in }
        brain.prewarmIfCold()                      // a real request just touched the cache
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.prewarms.count, 1)
    }

    /// Writes the first spoken chunk of every logged reply, old rule and new, for scripts/tts-bench.
    /// Runs only when JARVIS_DUMP_CHUNKS names an output file.
    func testDumpFirstChunksForBenchmark() throws {
        guard let out = ProcessInfo.processInfo.environment["JARVIS_DUMP_CHUNKS"], !out.isEmpty else { return }
        let log = try String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Jarvis/conversations.log"), encoding: .utf8)
        var rows: [[String: String]] = []
        for part in log.components(separatedBy: "\n    Jarvis: ").dropFirst() {
            let reply = part.components(separatedBy: "\n20").first ?? part
            let text = reply.replacingOccurrences(of: #"\s+\[tools:.*\]$"#, with: "", options: .regularExpression)
            guard let old = chunks(text, minWords: 0).first, let new = chunks(text, minWords: 3).first else { continue }
            rows.append(["old": old, "new": new])
        }
        try JSONSerialization.data(withJSONObject: rows, options: .prettyPrinted).write(to: URL(fileURLWithPath: out))
    }
}
