import CoreGraphics
import Foundation

/// One face found in a camera frame. Points are in pixels, origin top-left. "Left" and "right" are as
/// they appear in the picture, not the person's own left and right.
public struct FaceObservation: Equatable, Sendable {
    public var box: CGRect
    public var leftEye: CGPoint
    public var rightEye: CGPoint
    public var nose: CGPoint
    public var mouthLeft: CGPoint
    public var mouthRight: CGPoint
    /// Eye height divided by eye width, averaged over both eyes. Drops sharply during a blink.
    public var eyeOpenness: Double

    public init(box: CGRect, leftEye: CGPoint, rightEye: CGPoint, nose: CGPoint, mouthLeft: CGPoint, mouthRight: CGPoint, eyeOpenness: Double) {
        self.box = box; self.leftEye = leftEye; self.rightEye = rightEye; self.nose = nose
        self.mouthLeft = mouthLeft; self.mouthRight = mouthRight; self.eyeOpenness = eyeOpenness
    }

    public var eyeDistance: Double { Double(hypot(rightEye.x - leftEye.x, rightEye.y - leftEye.y)) }

    /// Where the nose sits along the line between the eyes, as a fraction of the eye distance, measured
    /// from the midpoint. A real head turning moves the nose along this line because the nose sticks out.
    /// A flat photo turning does not: everything on it shrinks together.
    public var noseOffset: Double {
        let d = eyeDistance
        guard d > 1 else { return 0 }
        let ax = Double(rightEye.x - leftEye.x) / d, ay = Double(rightEye.y - leftEye.y) / d
        let mx = Double(leftEye.x + rightEye.x) / 2, my = Double(leftEye.y + rightEye.y) / 2
        return ((Double(nose.x) - mx) * ax + (Double(nose.y) - my) * ay) / d
    }
}

public enum FaceAlign {
    /// The side of the square crop the face model expects.
    public static let side = 112
    /// Where the eyes and mouth corners belong in that crop (the standard ArcFace layout).
    public static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    public static func anchors(_ f: FaceObservation) -> [CGPoint] { [f.leftEye, f.rightEye, f.mouthLeft, f.mouthRight] }

    /// The best rotate + scale + move (no mirroring, no skew) that carries `from` onto `to`.
    public static func similarity(from: [CGPoint], to: [CGPoint]) -> CGAffineTransform? {
        guard from.count == to.count, from.count >= 2 else { return nil }
        let n = Double(from.count)
        let pc = from.reduce((0.0, 0.0)) { ($0.0 + Double($1.x), $0.1 + Double($1.y)) }
        let qc = to.reduce((0.0, 0.0)) { ($0.0 + Double($1.x), $0.1 + Double($1.y)) }
        let (px, py, qx, qy) = (pc.0 / n, pc.1 / n, qc.0 / n, qc.1 / n)
        var dot = 0.0, cross = 0.0, norm = 0.0
        for (p, q) in zip(from, to) {
            let (ax, ay, bx, by) = (Double(p.x) - px, Double(p.y) - py, Double(q.x) - qx, Double(q.y) - qy)
            dot += ax * bx + ay * by
            cross += ax * by - ay * bx
            norm += ax * ax + ay * ay
        }
        guard norm > 1e-9 else { return nil }
        let a = dot / norm, b = cross / norm
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: qx - (a * px - b * py), ty: qy - (b * px + a * py))
    }

    /// The transform that puts this face into the model's crop, or nil when the face is too small or odd.
    public static func transform(for face: FaceObservation) -> CGAffineTransform? {
        guard face.eyeDistance >= 24 else { return nil }      // fewer pixels than this is guesswork
        return similarity(from: anchors(face), to: template)
    }
}

public enum FaceMath {
    public static func normalized(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return -1 }
        return Double(dot / (sqrt(na) * sqrt(nb)))
    }
    public static func centroid(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == first.count { for i in v.indices { sum[i] += v[i] } }
        return normalized(sum)
    }
    public static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// Basic "is this a live person" check from a run of frames of one face. It passes on either sign:
///   - a blink: the eyes close and open again within a second;
///   - a small head turn: the nose moves along the eye line by more than a flat picture could explain.
/// It stops a printed photo and a still picture on a phone. It does NOT stop a video of the owner
/// blinking, or a good mask; nothing that uses an ordinary webcam can.
public struct LivenessTracker: Equatable, Sendable {
    public struct Settings: Equatable, Sendable {
        /// Eyes count as shut below this fraction of their usual openness…
        public var shutFraction = 0.62
        /// …and as open again above this one.
        public var openFraction = 0.85
        public var blinkWithin: TimeInterval = 1.0
        /// How far the nose must travel along the eye line, as a fraction of the eye distance.
        public var turnDelta = 0.08
        /// Only this much history is looked at.
        public var window: TimeInterval = 8
        /// A gap this long between frames means it may be a different face: start again.
        public var gap: TimeInterval = 2
        public init() {}
    }
    public private(set) var isLive = false
    public private(set) var reason: String?
    public var settings: Settings

    private struct Sample: Equatable, Sendable { var at: Date; var openness: Double; var offset: Double }
    private var samples: [Sample] = []
    private var shutAt: Date?

    public init(settings: Settings = Settings()) { self.settings = settings }

    public mutating func reset() { samples = []; shutAt = nil; isLive = false; reason = nil }

    /// Feed one frame of the same face. Returns true once this face has shown a sign of life.
    @discardableResult
    public mutating func add(openness: Double, noseOffset: Double, at now: Date) -> Bool {
        if let last = samples.last, now.timeIntervalSince(last.at) > settings.gap { reset() }
        samples.append(Sample(at: now, openness: openness, offset: noseOffset))
        samples.removeAll { now.timeIntervalSince($0.at) > settings.window }
        guard !isLive, samples.count >= 4 else { return isLive }

        // Blink. "Usual openness" is the upper part of what was seen, so a blink does not drag it down.
        let sorted = samples.map(\.openness).sorted()
        let usual = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.75))]
        if usual > 0.08 {
            if openness <= usual * settings.shutFraction {
                if shutAt == nil { shutAt = now }
            } else if let shut = shutAt {
                if openness >= usual * settings.openFraction {
                    if now.timeIntervalSince(shut) <= settings.blinkWithin { isLive = true; reason = "blink" }
                    shutAt = nil
                } else if now.timeIntervalSince(shut) > settings.blinkWithin { shutAt = nil }
            }
        }
        // Head turn. Medians of three frames, so one jittery frame cannot fake it.
        if !isLive, samples.count >= 6 {
            let offsets = samples.map(\.offset)
            var smooth: [Double] = []
            for i in 1..<(offsets.count - 1) { smooth.append(FaceMath.median([offsets[i - 1], offsets[i], offsets[i + 1]])) }
            if let lo = smooth.min(), let hi = smooth.max(), hi - lo >= settings.turnDelta { isLive = true; reason = "head turn" }
        }
        return isLive
    }
}
