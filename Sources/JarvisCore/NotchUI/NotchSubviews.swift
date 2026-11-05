import SwiftUI

/// Live microphone waveform: one capsule per level sample.
public struct WaveformView: View {
    public var levels: [Float]
    public var reduceMotion: Bool

    public init(levels: [Float], reduceMotion: Bool) {
        self.levels = levels; self.reduceMotion = reduceMotion
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color(red: 0.36, green: 0.66, blue: 1.0))
                    .frame(width: 3, height: 3 + CGFloat(levels[i]) * 16)
            }
        }
        .frame(height: 20)
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: levels)
    }
}

/// Three dots that pulse in sequence while Claude is working.
public struct ThinkingDots: View {
    public var reduceMotion: Bool
    public init(reduceMotion: Bool) { self.reduceMotion = reduceMotion }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = reduceMotion ? 1.0 : 0.55 + 0.45 * sin(t * 4 - Double(i) * 0.9)
                    Circle()
                        .fill(Color(red: 0.72, green: 0.5, blue: 1.0))
                        .frame(width: 6, height: 6)
                        .opacity(phase)
                        .scaleEffect(0.8 + 0.2 * phase)
                }
            }
        }
    }
}

/// Today's remaining tasks, next deadlines, exams with days left.
public struct BriefingCardView: View {
    public var data: BriefingData
    public init(data: BriefingData) { self.data = data }

    public var body: some View {
        HStack(alignment: .top, spacing: 14) {
            column("Today", icon: "checklist", items: data.tasks, empty: "Nothing left. Nice.")
            divider
            column("Deadlines", icon: "calendar.badge.clock", items: data.deadlines, empty: "None coming up")
            divider
            column("Exams", icon: "graduationcap", items: data.exams, empty: "None in 14 days")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07)))
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1)
    }

    private func column(_ title: String, icon: String, items: [BriefingData.Item], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.bottom, 2)
            if items.isEmpty {
                Text(empty).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
            ForEach(items.prefix(4)) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let d = item.daysLeft {
                        Text(d == 0 ? "today" : d == 1 ? "1 day" : "\(d) days")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(d <= 1 ? Color(red: 1, green: 0.45, blue: 0.4) : d <= 3 ? Color(red: 1, green: 0.75, blue: 0.3) : .white.opacity(0.6))
                    } else if let detail = item.detail {
                        Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Generic titled list card (used for results, timers, "what did you do today").
public struct InfoCardView: View {
    public var title: String
    public var lines: [String]
    public init(title: String, lines: [String]) { self.title = title; self.lines = lines }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            ForEach(lines.indices, id: \.self) { i in
                Text(lines[i]).font(.system(size: 11)).foregroundStyle(.white).lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07)))
    }
}
