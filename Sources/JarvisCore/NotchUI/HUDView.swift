import SwiftUI

/// Full-screen Iron Man-style HUD: arc reactor in the middle, flight-check readouts around it,
/// transcript and reply along the bottom. Driven by the same NotchViewModel as the notch.
public struct HUDView: View {
    @ObservedObject var model: NotchViewModel
    public var readouts: HUDReadouts
    public var onDismiss: () -> Void

    public init(model: NotchViewModel, readouts: HUDReadouts, onDismiss: @escaping () -> Void) {
        self.model = model; self.readouts = readouts; self.onDismiss = onDismiss
    }

    static let cyan = Color(red: 0.35, green: 0.86, blue: 1.0)
    static let gold = Color(red: 1.0, green: 0.78, blue: 0.35)

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.9)
                GridBackdrop().opacity(0.25)
                ArcReactor(phase: model.phase, level: model.audioLevels.last ?? 0, reduceMotion: model.reduceMotion)
                    .frame(width: min(geo.size.width, geo.size.height) * 0.46)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.42)

                VStack(alignment: .leading, spacing: 6) {
                    Text("J.A.R.V.I.S.").font(.system(size: 22, weight: .semibold, design: .monospaced)).tracking(6)
                    Text(readouts.title).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Self.cyan.opacity(0.8))
                    Rectangle().fill(Self.cyan.opacity(0.4)).frame(width: 220, height: 1).padding(.vertical, 6)
                    ForEach(readouts.left, id: \.self) { line in
                        Text(line).font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .foregroundStyle(Self.cyan)
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(readouts.rightTitle).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Self.gold)
                    Rectangle().fill(Self.gold.opacity(0.4)).frame(width: 260, height: 1).padding(.vertical, 6)
                    ForEach(readouts.right, id: \.self) { line in
                        Text(line).font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                VStack(spacing: 10) {
                    if !model.transcript.isEmpty {
                        Text("› " + model.transcript)
                            .font(.system(size: 15, design: .monospaced)).foregroundStyle(Self.cyan.opacity(0.9))
                    }
                    if !model.replyText.isEmpty {
                        Text(model.replyText)
                            .font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: geo.size.width * 0.6)
                    }
                    Text(statusLine).font(.system(size: 11, design: .monospaced)).foregroundStyle(Self.cyan.opacity(0.6)).padding(.top, 6)
                    Text("click or press esc to dismiss").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                }
                .padding(.bottom, 50)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .contentShape(Rectangle())
            .onTapGesture { onDismiss() }
        }
        .ignoresSafeArea()
    }

    private var statusLine: String {
        switch model.phase {
        case .idle: return "STANDBY"
        case .listening: return "LISTENING ▸ ▸ ▸"
        case .thinking: return "PROCESSING"
        case .responding: return "ONLINE"
        }
    }
}

public struct HUDReadouts: Equatable {
    public var title: String
    public var left: [String]
    public var rightTitle: String
    public var right: [String]
    public init(title: String, left: [String], rightTitle: String, right: [String]) {
        self.title = title; self.left = left; self.rightTitle = rightTitle; self.right = right
    }
    public static let empty = HUDReadouts(title: "", left: [], rightTitle: "", right: [])
}

/// Concentric rotating rings with tick marks and a core that pulses with the mic level.
struct ArcReactor: View {
    var phase: NotchPhase
    var level: Float
    var reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
            let t = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate
            let speed: Double = phase == .thinking ? 2.2 : phase == .listening ? 1.2 : 0.5
            let glow = Double(level) * 0.8 + (phase == .responding ? 0.35 : 0.15) + 0.1 * sin(t * 2)
            ZStack {
                Circle().fill(RadialGradient(colors: [HUDView.cyan.opacity(0.55 * glow + 0.15), .clear], center: .center, startRadius: 0, endRadius: 140))
                ring(radius: 1.0, dash: [2, 10], width: 2, speed: speed * 0.6, t: t, color: HUDView.cyan.opacity(0.7))
                ring(radius: 0.86, dash: [28, 14], width: 4, speed: -speed * 0.9, t: t, color: HUDView.cyan.opacity(0.5))
                ring(radius: 0.72, dash: [6, 6], width: 1.5, speed: speed * 1.5, t: t, color: HUDView.gold.opacity(0.7))
                ring(radius: 0.58, dash: [60, 30], width: 6, speed: -speed * 0.4, t: t, color: HUDView.cyan.opacity(0.35))
                Circle().strokeBorder(HUDView.cyan.opacity(0.8), lineWidth: 1).scaleEffect(0.42)
                Circle().fill(HUDView.cyan.opacity(0.15 + 0.5 * glow)).scaleEffect(0.36 + CGFloat(level) * 0.06)
                    .blur(radius: 6)
                Circle().fill(Color.white.opacity(0.75 + 0.25 * glow)).scaleEffect(0.12 + CGFloat(level) * 0.05)
                    .shadow(color: HUDView.cyan, radius: 20 + CGFloat(level) * 30)
            }
        }
    }

    func ring(radius: CGFloat, dash: [CGFloat], width: CGFloat, speed: Double, t: Double, color: Color) -> some View {
        Circle()
            .strokeBorder(color, style: StrokeStyle(lineWidth: width, dash: dash))
            .scaleEffect(radius)
            .rotationEffect(.degrees((t * speed * 40).truncatingRemainder(dividingBy: 360)))
    }
}

struct GridBackdrop: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            let step: CGFloat = 60
            var x: CGFloat = 0
            while x <= size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = 0
            while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.stroke(path, with: .color(HUDView.cyan.opacity(0.12)), lineWidth: 0.5)
        }
    }
}
