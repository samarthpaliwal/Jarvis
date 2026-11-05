import Foundation

/// Drives the notch through fake conversations so the UI can be tested before
/// the microphone, speech, and Claude are wired up (Milestones 2–4).
@MainActor
public final class DemoDriver {
    private let notch: NotchViewModel
    private let config: ConfigStore
    private var task: Task<Void, Never>?

    public init(notch: NotchViewModel, config: ConfigStore) {
        self.notch = notch
        self.config = config
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    /// Full round trip: listening with a waveform, thinking, then a spoken-style reply.
    public func runConversation() {
        cancel()
        task = Task { [notch] in
            notch.listen()
            let words = ["what's", "left", "today?"]
            var heard = ""
            for i in 0..<36 {
                guard !Task.isCancelled else { return }
                notch.pushAudioLevel(Float.random(in: 0.1...1.0) * (i % 9 == 0 ? 0.3 : 1))
                if i % 8 == 7, words.indices.contains(i / 8) {
                    heard += (heard.isEmpty ? "" : " ") + words[i / 8]
                    notch.transcript = heard
                }
                try? await Task.sleep(for: .milliseconds(70))
            }
            notch.think()
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            notch.respond("Two things left, \(self.config.profile.assistant.addressUserAs): the CSC 210 problem set and a 4pm gym block. Your exam is in 6 days.",
                          cards: [.briefing(Self.sampleBriefing)], collapseAfter: 10)
        }
    }

    public func runBriefing() {
        cancel()
        notch.transcript = ""
        notch.respond("Morning, \(config.profile.assistant.addressUserAs). Two things today, and your CSC exam is in 6 days.",
                      cards: [.briefing(Self.sampleBriefing)], collapseAfter: 12)
    }

    public func runListening() {
        cancel()
        task = Task { [notch] in
            notch.listen()
            while !Task.isCancelled {
                notch.pushAudioLevel(Float.random(in: 0.05...0.9))
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    public func runThinking() {
        cancel()
        notch.think()
    }

    public func runOneLiner() {
        cancel()
        notch.flash("Moved 14 files into Desktop/Sorted. Say \"undo that\" to put them back.", seconds: 5)
    }

    public static let sampleBriefing = BriefingData(
        tasks: [
            .init(title: "CSC 210 problem set", detail: "due 11:59pm"),
            .init(title: "Gym", detail: "4:00pm"),
        ],
        deadlines: [
            .init(title: "MATH 129 homework 7", daysLeft: 2),
            .init(title: "ENGL essay draft", daysLeft: 4),
            .init(title: "Internship app: Stripe", daysLeft: 9),
        ],
        exams: [
            .init(title: "CSC 210 midterm", daysLeft: 6),
            .init(title: "MATH 129 quiz", daysLeft: 11),
        ]
    )
}
