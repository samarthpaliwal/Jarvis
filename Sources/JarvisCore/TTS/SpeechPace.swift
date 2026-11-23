import Foundation

/// How fast Jarvis talks, as one number: 1.0 is each voice's natural pace, 1.3 is 30% faster.
/// It lives in profile.json as `assistant.speechSpeed` and every voice engine is driven from it.
public enum SpeechPace {
    public static let defaultSpeed = 1.3
    public static let range: ClosedRange<Double> = 0.7...2.0
    public static let step = 0.1
    /// The speed in force right now (set from the config when it loads or changes).
    public nonisolated(unsafe) static var current = defaultSpeed

    public static func clamp(_ speed: Double) -> Double {
        guard speed.isFinite else { return defaultSpeed }
        return (min(range.upperBound, max(range.lowerBound, speed)) * 100).rounded() / 100
    }

    /// One step faster or slower from `speed`, kept inside the range.
    public static func nudged(_ speed: Double, faster: Bool) -> Double { clamp(speed + (faster ? step : -step)) }

    /// Apple's scale is not a multiplier: 0.5 is normal and about 0.75 is twice as fast.
    public static func appleRate(base: Double, speed: Double = current) -> Float {
        Float(min(0.8, max(0.3, base + (clamp(speed) - 1) * 0.25)))
    }
    /// Kokoro takes a plain multiplier; `base` is the older per-voice trim in `voice.kokoroSpeed`.
    public static func kokoro(base: Double, speed: Double = current) -> Double {
        (min(2.0, max(0.5, base * clamp(speed))) * 100).rounded() / 100
    }
    /// ElevenLabs only accepts 0.7 to 1.2.
    public static func elevenLabs(speed: Double = current) -> Double { min(1.2, max(0.7, clamp(speed))) }
    /// OpenAI's `speed` field: 0.25 to 4. Only the tts-1 models honour it.
    public static func openAI(speed: Double = current) -> Double { clamp(speed) }

    public static func spoken(_ speed: Double) -> String {
        let pct = Int(((clamp(speed) - 1) * 100).rounded())
        if pct == 0 { return "normal speed" }
        return pct > 0 ? "\(pct) percent faster than normal" : "\(-pct) percent slower than normal"
    }
}
