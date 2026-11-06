import SwiftUI

/// The Jarvis card: a dark rounded panel with status, live transcript, reply, and cards. No glow, no halo.
public struct FloatingCardView: View {
    @ObservedObject var model: NotchViewModel
    var onClose: () -> Void
    public static let width: CGFloat = 560

    public init(model: NotchViewModel, onClose: @escaping () -> Void) { self.model = model; self.onClose = onClose }

    static let blue = Color(red: 0.42, green: 0.70, blue: 1.0)
    static let violet = Color(red: 0.70, green: 0.55, blue: 1.0)

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.phase == .responding {
                if !model.transcript.isEmpty {
                    Text("“\(model.transcript)”").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                }
                if !model.replyText.isEmpty {
                    Text(model.replyText)
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.cards) { card in
                    switch card {
                    case .briefing(let data): BriefingCardView(data: data)
                    case .info(let title, let lines): InfoCardView(title: title, lines: lines)
                    case .approval(let request): ApprovalCardView(request: request) { ok in model.onApprovalDecision?(request.id, ok) }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(white: 0.08))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        )
        .animation(model.reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: model.phase)
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.2), value: model.replyText)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(iconColor.opacity(0.18)).frame(width: 30, height: 30)
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(iconColor)
            }
            Text(title)
                .font(.system(size: 14, weight: model.phase == .listening && !model.transcript.isEmpty ? .regular : .semibold))
                .foregroundStyle(.white.opacity(model.phase == .listening && model.transcript.isEmpty ? 0.6 : 1))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            trailing
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.45))
                    .frame(width: 22, height: 22).background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Dismiss (Jarvis stops talking)")
        }
    }

    private var icon: String {
        switch model.phase {
        case .listening: return "mic.fill"
        case .thinking: return "sparkles"
        default: return "waveform"
        }
    }
    private var iconColor: Color {
        switch model.phase {
        case .listening: return Self.blue
        case .thinking: return Self.violet
        default: return .white
        }
    }
    private var title: String {
        switch model.phase {
        case .listening: return model.transcript.isEmpty ? (model.isFollowUp ? "Go on…" : "Listening…") : model.transcript
        case .thinking: return "Thinking…"
        case .responding, .idle: return "Jarvis"
        }
    }
    @ViewBuilder private var trailing: some View {
        switch model.phase {
        case .listening: WaveformView(levels: Array(model.audioLevels.suffix(18)), reduceMotion: model.reduceMotion)
        case .thinking: ThinkingDots(reduceMotion: model.reduceMotion)
        default:
            Image(systemName: model.modeIcon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
        }
    }
}
