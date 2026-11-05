import SwiftUI

/// The iridescent palette Apple uses for Siri / Apple Intelligence, looped for an angular gradient.
public enum SiriPalette {
    public static let colors: [Color] = [
        Color(red: 0.31, green: 0.64, blue: 1.00),  // blue
        Color(red: 0.55, green: 0.36, blue: 1.00),  // violet
        Color(red: 1.00, green: 0.36, blue: 0.66),  // pink
        Color(red: 1.00, green: 0.54, blue: 0.24),  // orange
        Color(red: 1.00, green: 0.82, blue: 0.24),  // yellow
        Color(red: 0.31, green: 0.64, blue: 1.00),  // back to blue
    ]

    public static func gradient(angle: Angle) -> AngularGradient {
        AngularGradient(colors: colors, center: .center, angle: angle)
    }
}

/// A rotating, blurred iridescent stroke around any shape. Pure SwiftUI, no layers.
public struct SiriGlowStroke<S: InsettableShape>: View {
    public var shape: S
    public var lineWidth: CGFloat
    public var blur: CGFloat
    public var opacity: Double
    public var degreesPerSecond: Double
    public var breathe: Bool
    public var paused: Bool

    public init(shape: S, lineWidth: CGFloat, blur: CGFloat, opacity: Double,
                degreesPerSecond: Double = 60, breathe: Bool = true, paused: Bool) {
        self.shape = shape
        self.lineWidth = lineWidth
        self.blur = blur
        self.opacity = opacity
        self.degreesPerSecond = degreesPerSecond
        self.breathe = breathe
        self.paused = paused
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 40, paused: paused)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = Angle(degrees: paused ? 0 : (t * degreesPerSecond).truncatingRemainder(dividingBy: 360))
            let breath = (breathe && !paused) ? 0.85 + 0.15 * sin(t * 2.4) : 1.0
            ZStack {
                shape.strokeBorder(SiriPalette.gradient(angle: angle), lineWidth: lineWidth)
                    .blur(radius: blur)
                shape.strokeBorder(SiriPalette.gradient(angle: angle + .degrees(40)), lineWidth: lineWidth * 0.35)
                    .blur(radius: blur * 0.25)
            }
            .opacity(opacity * breath)
        }
    }
}

/// Full-screen edge glow, like Siri on macOS. Drawn in its own click-through panel.
public struct EdgeGlowView: View {
    @ObservedObject var model: NotchViewModel

    public init(model: NotchViewModel) { self.model = model }

    public var body: some View {
        let active = model.edgeGlow > 0
        ZStack {
            SiriGlowStroke(shape: RoundedRectangle(cornerRadius: 22, style: .continuous),
                           lineWidth: 26, blur: 30, opacity: 0.75,
                           degreesPerSecond: 35, breathe: true,
                           paused: !active || model.reduceMotion)
            SiriGlowStroke(shape: RoundedRectangle(cornerRadius: 22, style: .continuous),
                           lineWidth: 6, blur: 4, opacity: 0.9,
                           degreesPerSecond: 35, breathe: false,
                           paused: !active || model.reduceMotion)
        }
        .padding(-6)
        .opacity(model.edgeGlow)
        .scaleEffect(active ? 1.0 : 1.02)
        .animation(model.reduceMotion ? .easeInOut(duration: 0.25) : .easeInOut(duration: 0.55), value: model.edgeGlow)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
