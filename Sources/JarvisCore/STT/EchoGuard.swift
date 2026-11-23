import Foundation

/// Tells Jarvis's own voice, picked up by the microphone, apart from the user talking.
///
/// On built-in speakers the mic hears everything Jarvis says. The recognizer then returns a garbled
/// copy of the reply ("transcripts" for "transcription", "Tuxo" for "Tucson"), so the comparison is
/// fuzzy: words match when they are equal or share a four-letter stem, and word order counts.
public enum EchoGuard {
    public struct Similarity: Equatable {
        /// Number of words heard.
        public var words: Int
        /// Share of heard words that Jarvis also said (0…1).
        public var overlap: Double
        /// Share of heard words that appear in the same order in what Jarvis said (0…1).
        public var ordered: Double
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 4, b.count >= 4 else { return false }
        return a.prefix(4) == b.prefix(4)
    }

    public static func similarity(heard: String, spoken: String) -> Similarity {
        let h = words(heard), s = words(spoken)
        guard !h.isEmpty, !s.isEmpty else { return Similarity(words: h.count, overlap: 0, ordered: 0) }
        let overlap = Double(h.filter { w in s.contains { same(w, $0) } }.count) / Double(h.count)
        // Longest common subsequence: how much of what was heard follows the reply's word order.
        var previous = [Int](repeating: 0, count: s.count + 1)
        for hw in h {
            var current = [Int](repeating: 0, count: s.count + 1)
            for (j, sw) in s.enumerated() {
                current[j + 1] = same(hw, sw) ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            previous = current
        }
        return Similarity(words: h.count, overlap: overlap, ordered: Double(previous[s.count]) / Double(h.count))
    }

    /// Heard while Jarvis is still talking. Be strict: anything that mostly matches the reply is echo.
    public static func isEchoWhileSpeaking(heard: String, spoken: String) -> Bool {
        let sim = similarity(heard: heard, spoken: spoken)
        guard sim.words > 0, !words(spoken).isEmpty else { return false }
        return sim.overlap >= 0.5 || sim.ordered >= 0.4
    }

    /// Heard on a follow-up listen after Jarvis finished. Be careful: people repeat Jarvis's words
    /// when they answer ("yes, start something on Spotify"), so only a long, in-order copy is echo.
    public static func isEchoAfterSpeaking(heard: String, spoken: String) -> Bool {
        let sim = similarity(heard: heard, spoken: spoken)
        return sim.words >= 6 && sim.overlap >= 0.7 && sim.ordered >= 0.6
    }
}
