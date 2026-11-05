import AppKit
import Combine

public enum NotchPhase: String, Equatable {
    case idle, listening, thinking, responding
}

/// Data for the briefing card. Filled from calendar / Notion / email in Milestone 5.
public struct BriefingData: Equatable, Sendable {
    public struct Item: Equatable, Identifiable, Sendable {
        public var id: String { title + (detail ?? "") }
        public var title: String
        public var detail: String?
        public var daysLeft: Int?
        public init(title: String, detail: String? = nil, daysLeft: Int? = nil) {
            self.title = title; self.detail = detail; self.daysLeft = daysLeft
        }
    }
    public var tasks: [Item]
    public var deadlines: [Item]
    public var exams: [Item]
    public init(tasks: [Item], deadlines: [Item], exams: [Item]) {
        self.tasks = tasks; self.deadlines = deadlines; self.exams = exams
    }
}

/// A card rendered under the reply text. More cases arrive with later milestones (approval, timer, results).
public enum NotchCard: Equatable, Identifiable, Sendable {
    case briefing(BriefingData)
    case info(title: String, lines: [String])
    case approval(ApprovalRequest)

    public var id: String {
        switch self {
        case .briefing: return "briefing"
        case .info(let title, _): return "info-\(title)"
        case .approval(let r): return "approval-\(r.id)"
        }
    }
}

/// Single source of truth for what the notch shows. Drive it from anywhere on the main actor.
@MainActor
public final class NotchViewModel: ObservableObject {
    @Published public var phase: NotchPhase = .idle
    @Published public var geometry: NotchGeometry = .fallback
    /// Live speech-to-text while listening.
    @Published public var transcript: String = ""
    @Published public var replyText: String = ""
    @Published public var cards: [NotchCard] = []
    /// Rolling audio levels 0...1 for the waveform.
    @Published public var audioLevels: [Float] = Array(repeating: 0, count: 28)
    @Published public var modeIcon: String = "house.fill"
    @Published public var modeName: String = "Home"
    @Published public var doNotDisturb: Bool = false
    @Published public var isHovering: Bool = false
    /// 0...1, from the active mode. Scales the listening glow.
    @Published public var glowStrength: Double = 1.0
    /// 0...1 opacity of the full-screen Siri-style edge glow.
    @Published public var edgeGlow: Double = 0

    /// Recent exchanges for the HUD (you / Jarvis), newest last.
    public struct Exchange: Equatable, Identifiable { public let id = UUID(); public var you: String; public var jarvis: String }
    @Published public var log: [Exchange] = []
    public func logExchange(you: String, jarvis: String) {
        log.append(Exchange(you: you, jarvis: jarvis))
        if log.count > 6 { log.removeFirst(log.count - 6) }
    }
    /// True while listening for a follow-up (no wake word): a calmer glow.
    @Published public var isFollowUp = false

    /// Resolves the approval card's buttons. Set by the conversation controller.
    public var onApprovalDecision: ((UUID, Bool) -> Void)?

    /// Append streamed text to the reply while responding.
    public func appendReply(_ delta: String) {
        if phase != .responding { replyText = ""; cards = []; phase = .responding; edgeGlow = 0 }
        replyText += delta
    }

    public func addCard(_ card: NotchCard) {
        cards.removeAll { $0.id == card.id }
        cards.append(card)
    }

    public func removeCard(id: String) { cards.removeAll { $0.id == id } }

    public var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var collapseTask: Task<Void, Never>?

    public init() {}

    // MARK: Phase transitions

    public func listen() {
        cancelCollapse()
        transcript = ""
        phase = .listening
        edgeGlow = isFollowUp ? glowStrength * 0.35 : glowStrength
    }

    public func think() {
        cancelCollapse()
        phase = .thinking
        edgeGlow = 0
    }

    public func respond(_ text: String, cards: [NotchCard] = [], collapseAfter seconds: Double = 8) {
        replyText = text
        self.cards = cards
        phase = .responding
        edgeGlow = 0
        scheduleCollapse(after: seconds)
    }

    /// Show a short one-liner (mode change, "done, undo?") without the full response layout.
    public func flash(_ text: String, seconds: Double = 3) {
        transcript = ""
        respond(text, cards: [], collapseAfter: seconds)
    }

    public func collapse() {
        cancelCollapse()
        phase = .idle
        isFollowUp = false
        edgeGlow = 0
        audioLevels = Array(repeating: 0, count: audioLevels.count)
    }

    public func pushAudioLevel(_ level: Float) {
        guard phase == .listening else { return }
        audioLevels.removeFirst()
        audioLevels.append(max(0, min(1, level)))
    }

    // MARK: Auto-collapse

    public func scheduleCollapse(after seconds: Double) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            if self.isHovering {
                // Keep it open while the pointer is on it, then re-check.
                self.scheduleCollapse(after: 2)
            } else if self.phase == .responding {
                self.collapse()
            }
        }
    }

    public func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }
}
