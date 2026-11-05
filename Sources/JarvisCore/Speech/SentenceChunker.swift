import Foundation

/// Splits a streaming text into sentences so TTS can start before Claude finishes.
public struct SentenceChunker {
    private var buffer = ""
    public init() {}

    /// Feed a delta; returns any complete sentences.
    public mutating func push(_ text: String) -> [String] {
        buffer += text
        var out: [String] = []
        while let r = buffer.range(of: #"[.!?](\s+|$)"#, options: .regularExpression) {
            // Avoid splitting on decimals ("3.5 hours") or abbreviations like "e.g."
            let end = r.upperBound
            let sentence = String(buffer[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.looksLikeAbbreviation(sentence) && end < buffer.endIndex { break }
            if end == buffer.endIndex && !buffer.hasSuffix(" ") && !buffer.hasSuffix("\n") { break } // wait for whitespace
            buffer.removeSubrange(..<end)
            if sentence.count > 1 { out.append(sentence) }
        }
        return out
    }

    /// Whatever is left when the stream ends.
    public mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    static func looksLikeAbbreviation(_ s: String) -> Bool {
        let last = s.split(separator: " ").last.map(String.init) ?? s
        if last.count <= 3 && last.hasSuffix(".") && last.dropLast().allSatisfy({ $0.isLetter }) { return true }
        if last.lowercased().hasPrefix("e.g") || last.lowercased().hasPrefix("i.e") { return true }
        if let c = last.dropLast().last, c.isNumber, s.hasSuffix(".") { return true }
        return false
    }
}
