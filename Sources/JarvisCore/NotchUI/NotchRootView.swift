import SwiftUI

/// The whole notch overlay. Sized by its content; anchored to the top of the panel.
public struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel

    public init(model: NotchViewModel) { self.model = model }

    private var g: NotchGeometry { model.geometry }
    private var open: Bool { model.phase != .idle }
    private var hoverPeek: Bool { model.phase == .idle && model.isHovering && g.hasNotch }
    /// Horizontal flare of the top corners. Zero when idle so the shape is exactly the notch.
    private var flare: CGFloat { (open || hoverPeek) ? 10 : 0 }

    /// Width of the body (excluding the flare), per phase.
    private var bodyWidth: CGFloat {
        switch model.phase {
        case .idle:       return g.notchWidth + (hoverPeek ? 120 : 0)
        case .listening:  return g.notchWidth + 280
        case .thinking:   return g.notchWidth + 180
        case .responding: return max(g.notchWidth + 340, 580)
        }
    }
    private var headerHeight: CGFloat { g.notchHeight + ((open || hoverPeek) ? 8 : 0) }
    private var bottomRadius: CGFloat { open ? 20 : (g.hasNotch ? 10 : 12) }

    private var animation: Animation {
        model.reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.78)
    }

    private var glowColor: Color {
        switch model.phase {
        case .listening:  return Color(red: 0.36, green: 0.66, blue: 1.0).opacity(0.9 * model.glowStrength)
        case .thinking:   return Color(red: 0.72, green: 0.5, blue: 1.0).opacity(0.7 * model.glowStrength)
        case .responding: return Color.white.opacity(0.18 * model.glowStrength)
        case .idle:       return .clear
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, flare)
                .background {
                    GlowingShape(topRadius: flare, bottomRadius: bottomRadius,
                                 glow: glowColor, pulsing: model.phase == .listening || model.phase == .thinking,
                                 reduceMotion: model.reduceMotion, phase: model.phase, strength: model.glowStrength)
                }
                .onHover { model.isHovering = $0 }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(animation, value: model.phase)
        .animation(animation, value: model.isHovering)
        .animation(animation, value: model.geometry)
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: 0) {
            header
                .frame(width: bodyWidth, height: headerHeight)
            if model.phase == .responding {
                responseBody
                    .frame(width: bodyWidth, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    /// Top row: content sits left and right of the physical notch, never under it.
    private var header: some View {
        let side = max(0, (bodyWidth - (g.hasNotch ? g.notchWidth : 0)) / 2)
        return HStack(spacing: 0) {
            leftCluster.frame(width: side, height: headerHeight)
            if g.hasNotch { Color.clear.frame(width: g.notchWidth) }
            rightCluster.frame(width: side, height: headerHeight)
        }
    }

    @ViewBuilder private var leftCluster: some View {
        switch model.phase {
        case .idle:
            if hoverPeek {
                HStack(spacing: 6) {
                    Image(systemName: model.doNotDisturb ? "moon.fill" : model.modeIcon)
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.doNotDisturb ? "Quiet" : model.modeName).font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                EmptyView()
            }
        case .listening:
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.36, green: 0.66, blue: 1.0))
                Text(model.transcript.isEmpty ? "Listening…" : model.transcript)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.72, green: 0.5, blue: 1.0))
                Text("Thinking").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .responding:
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Jarvis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var rightCluster: some View {
        switch model.phase {
        case .idle:
            if hoverPeek {
                Text(Date(), style: .time)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                EmptyView()
            }
        case .listening:
            WaveformView(levels: model.audioLevels, reduceMotion: model.reduceMotion)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .thinking:
            ThinkingDots(reduceMotion: model.reduceMotion)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .responding:
            HStack(spacing: 6) {
                if model.doNotDisturb {
                    Image(systemName: "moon.fill").font(.system(size: 11))
                }
                Image(systemName: model.modeIcon).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.7))
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var responseBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.transcript.isEmpty {
                Text("“\(model.transcript)”")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }
            if !model.replyText.isEmpty {
                Text(model.replyText)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.cards) { card in
                switch card {
                case .briefing(let data):
                    BriefingCardView(data: data)
                case .info(let title, let lines):
                    InfoCardView(title: title, lines: lines)
                case .approval(let request):
                    ApprovalCardView(request: request) { ok in model.onApprovalDecision?(request.id, ok) }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 14)
    }
}

/// Black island with an iridescent Siri-style glow behind it while listening / thinking.
private struct GlowingShape: View {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var glow: Color
    var pulsing: Bool
    var reduceMotion: Bool
    var phase: NotchPhase
    var strength: Double

    var body: some View {
        ZStack {
            if phase == .listening || phase == .thinking {
                SiriGlowStroke(shape: NotchShape(topRadius: topRadius, bottomRadius: bottomRadius),
                               lineWidth: phase == .listening ? 10 : 6,
                               blur: phase == .listening ? 14 : 10,
                               opacity: (phase == .listening ? 0.95 : 0.6) * strength,
                               degreesPerSecond: phase == .listening ? 90 : 40,
                               breathe: true,
                               paused: reduceMotion)
                    .padding(-2)
                    .transition(.opacity)
            }
            NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                .fill(Color.black)
                .shadow(color: phase == .responding ? glow : .clear, radius: 10, y: 2)
        }
        .animation(.easeInOut(duration: 0.35), value: phase)
    }
}
