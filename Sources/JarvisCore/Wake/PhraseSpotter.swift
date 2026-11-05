import Foundation

/// Spots extra wake phrases ("wake up, daddy's home") with on-device speech recognition.
/// openWakeWord only ships trained models for a few phrases, so this runs a transcriber on the
/// shared mic stream, restarting it every few seconds to keep the text short. It is only switched
/// on while an "arrival window" is open (or always, if configured), because it costs real CPU.
@MainActor
public final class PhraseSpotter {
    public struct Hit: Equatable { public var phrase: String; public var scene: String; public var heard: String }

    public var onHit: ((Hit) -> Void)?
    public private(set) var isActive = false
    public private(set) var activeUntil: Date?

    private nonisolated(unsafe) let transcriber: Transcriber
    private var phrases: [Profile.WakePhrase]
    private var restartTask: Task<Void, Never>?
    private var cooldownUntil = Date.distantPast
    private var windowTask: Task<Void, Never>?

    public init(transcriber: Transcriber, phrases: [Profile.WakePhrase]) {
        self.transcriber = transcriber
        self.phrases = phrases
    }

    public func update(phrases: [Profile.WakePhrase]) { self.phrases = phrases }

    /// Open a window of `minutes`; spotting stops automatically afterwards.
    public func openWindow(minutes: Int, reason: String) {
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        activeUntil = max(activeUntil ?? .distantPast, until)
        JarvisLog.info("Phrase spotting on for \(minutes) min (\(reason))")
        start()
        windowTask?.cancel()
        windowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled, let self, let u = self.activeUntil, u <= Date() else { return }
            self.stop(reason: "window closed")
        }
    }

    public func start() {
        guard !isActive, !phrases.isEmpty else { return }
        isActive = true
        beginSession()
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard let self, self.isActive else { return }
                self.transcriber.cancel()
                self.beginSession()
            }
        }
    }

    public func stop(reason: String) {
        guard isActive else { return }
        isActive = false
        activeUntil = nil
        restartTask?.cancel()
        windowTask?.cancel()
        transcriber.cancel()
        JarvisLog.info("Phrase spotting off (\(reason))")
    }

    /// Pause while a real conversation uses the mic; resumes if the window is still open.
    public func pause() {
        guard isActive else { return }
        isActive = false
        restartTask?.cancel()
        transcriber.cancel()
    }

    public func resumeIfWindowOpen() {
        if let u = activeUntil, u > Date(), !isActive { start() }
    }

    private func beginSession() {
        try? transcriber.start(onUpdate: { [weak self] u in self?.check(u.text) }, onError: { _ in })
    }

    /// Feed audio from the capture queue.
    public nonisolated func append(_ chunk: [Float]) { transcriber.append(samples: chunk) }

    private func check(_ text: String) {
        guard isActive, Date() >= cooldownUntil else { return }
        guard let hit = Self.match(text, phrases: phrases) else { return }
        cooldownUntil = Date().addingTimeInterval(10)
        JarvisLog.info("Phrase spotted: “\(hit.phrase)” in “\(text)”")
        transcriber.cancel()
        onHit?(hit)
        beginSession()
    }

    /// Pure matcher: normalized substring, or all words in order within the last 12 words.
    nonisolated public static func match(_ text: String, phrases: [Profile.WakePhrase]) -> Hit? {
        let words = normalize(text).split(separator: " ").map(String.init)
        let tail = words.suffix(12).joined(separator: " ")
        for p in phrases {
            for candidate in [p.phrase] + p.aliases {
                let c = normalize(candidate)
                if !c.isEmpty, tail.contains(c) { return Hit(phrase: p.phrase, scene: p.scene, heard: text) }
            }
        }
        return nil
    }

    nonisolated static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
