import Foundation

/// Splits a streaming text into sentences so TTS can start before Claude finishes.
public struct SentenceChunker {
    private var buffer = ""
    private var emittedAny = false
    /// The first chunk may end at a clause break (, ; : —) once it has this many words, so speech
    /// synthesis can start on "Good morning, Sam," instead of waiting for a 25-word sentence.
    /// Time to first audio grows with the length of the first chunk. 0 waits for the whole sentence.
    public var firstChunkMinWords: Int

    public init(firstChunkMinWords: Int = 0) { self.firstChunkMinWords = firstChunkMinWords }

    /// The opening clause, if the buffer holds one that is long enough and comes before the first sentence end.
    private mutating func takeOpeningClause() -> String? {
        guard firstChunkMinWords > 0, !emittedAny else { return nil }
        let sentenceEnd = buffer.range(of: #"[.!?](\s+|$)"#, options: .regularExpression)?.lowerBound ?? buffer.endIndex
        var from = buffer.startIndex
        // A break needs whitespace after it, so "1,000" and "9:30" never split.
        while let r = buffer.range(of: #"[,;:—–]\s+"#, options: .regularExpression, range: from..<buffer.endIndex), r.lowerBound < sentenceEnd {
            let clause = String(buffer[..<buffer.index(after: r.lowerBound)]).trimmingCharacters(in: .whitespacesAndNewlines)
            if clause.split(separator: " ").count >= firstChunkMinWords {
                buffer.removeSubrange(..<r.upperBound)
                return clause
            }
            from = r.upperBound
        }
        return nil
    }

    /// Feed a delta; returns any complete sentences.
    public mutating func push(_ text: String) -> [String] {
        buffer += text
        var out: [String] = []
        if let clause = takeOpeningClause() { out.append(clause); emittedAny = true }
        var from = buffer.startIndex
        while let r = buffer.range(of: #"[.!?]+(\s+|$)"#, options: .regularExpression, range: from..<buffer.endIndex) {
            let end = r.upperBound
            // Wait for whitespace after the mark: "3." may still become "3.5", "e." may become "e.g.".
            if end == buffer.endIndex && !buffer.hasSuffix(" ") && !buffer.hasSuffix("\n") { break }
            let sentence = String(buffer[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isNotASentenceEnd(sentence) {
                from = end          // keep looking further on; never stall the rest of the reply
                continue
            }
            buffer.removeSubrange(..<end)
            from = buffer.startIndex
            if sentence.count > 1 { out.append(sentence); emittedAny = true }
        }
        return out
    }

    /// Whatever is left when the stream ends.
    public mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        if !rest.isEmpty { emittedAny = true }
        return rest.isEmpty ? nil : rest
    }

    static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "approx", "est", "inc", "ltd"]

    /// True when the full stop at the end of `s` does not end a sentence: a title ("Dr."), an initial
    /// ("J."), a dotted abbreviation ("e.g.", "a.m.", "U.S."), or a list number on its own ("2.").
    ///
    /// The old rule treated every word of up to two letters as an abbreviation, so a sentence ending in
    /// "on.", "it." or "me." was never split, and neither was anything after it: the whole reply was
    /// spoken as one clip once the model had finished (26 s of silence in one logged reply).
    static func isNotASentenceEnd(_ s: String) -> Bool {
        guard s.hasSuffix("."), !s.hasSuffix("..") else { return false }   // "?" and "!" always end; so does "…"
        let last = s.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? s
        let word = String(last.dropLast()).lowercased()
        if word.isEmpty { return false }
        if word.contains(".") { return true }                                  // e.g. / a.m. / U.S.
        if word.count == 1, word.first!.isLetter, word != "i", word != "a" { return true }   // an initial
        if abbreviations.contains(word) { return true }
        if last == "No.", s != last { return true }                            // "ranked No. 3", but not a bare "No."
        if word.allSatisfy(\.isNumber), s == last { return true }             // "2." alone is a list marker
        return false
    }
}
