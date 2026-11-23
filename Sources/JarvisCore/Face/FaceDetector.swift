import CoreGraphics
import Foundation
import Vision

public enum FaceError: LocalizedError, Equatable {
    case modelMissing(String)
    case modelFailed(String)
    case notEnrolled
    case keyUnavailable
    case templateUnreadable
    case tooFewFrames(Int)
    case inconsistent(Double)
    case notConfirmed
    case busy

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let p): return "The face model is not installed (\(p)). Run scripts/setup-faceid.sh."
        case .modelFailed(let why): return "The face model failed: \(why)"
        case .notEnrolled: return "No face is enrolled yet."
        case .keyUnavailable: return "The key that protects the face data is locked. Unlock Jarvis with Touch ID first."
        case .templateUnreadable: return "The saved face data could not be read."
        case .tooFewFrames(let n): return "Only \(n) good pictures of a face were captured, which is not enough."
        case .inconsistent(let s): return "The pictures did not look like one person consistently (lowest match \(String(format: "%.2f", s)))."
        case .notConfirmed: return "Touch ID was not confirmed."
        case .busy: return "The face check is busy."
        }
    }
}

/// Finds faces and their landmarks in one picture.
public protocol FaceDetecting: Sendable {
    func detect(in image: CGImage) throws -> [FaceObservation]
}

/// Turns one found face into a list of numbers that is alike for the same person.
public protocol FaceEmbedding: AnyObject, Sendable {
    var modelName: String { get }
    func embed(_ image: CGImage, face: FaceObservation) throws -> [Float]
}

/// Apple's Vision framework: on-device, no network, nothing stored.
public struct VisionFaceDetector: FaceDetecting {
    public init() {}

    public func detect(in image: CGImage) throws -> [FaceObservation] {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { Self.observation($0, imageSize: size) }
    }

    static func observation(_ o: VNFaceObservation, imageSize: CGSize) -> FaceObservation? {
        guard let marks = o.landmarks, let eyeA = marks.leftEye, let eyeB = marks.rightEye, let lips = marks.outerLips,
              let nose = marks.nose ?? marks.noseCrest else { return nil }
        // Vision's origin is bottom-left; everything here is top-left.
        func points(_ r: VNFaceLandmarkRegion2D) -> [CGPoint] {
            r.pointsInImage(imageSize: imageSize).map { CGPoint(x: $0.x, y: imageSize.height - $0.y) }
        }
        func centre(_ ps: [CGPoint]) -> CGPoint? {
            guard !ps.isEmpty else { return nil }
            return CGPoint(x: ps.map(\.x).reduce(0, +) / CGFloat(ps.count), y: ps.map(\.y).reduce(0, +) / CGFloat(ps.count))
        }
        let a = points(eyeA), b = points(eyeB), mouth = points(lips)
        guard let ca = marks.leftPupil.flatMap({ centre(points($0)) }) ?? centre(a),
              let cb = marks.rightPupil.flatMap({ centre(points($0)) }) ?? centre(b),
              let n = centre(points(nose)),
              let ml = mouth.min(by: { $0.x < $1.x }), let mr = mouth.max(by: { $0.x < $1.x }) else { return nil }
        let (left, right) = ca.x <= cb.x ? (ca, cb) : (cb, ca)
        let box = CGRect(x: o.boundingBox.minX * imageSize.width, y: (1 - o.boundingBox.maxY) * imageSize.height,
                         width: o.boundingBox.width * imageSize.width, height: o.boundingBox.height * imageSize.height)
        return FaceObservation(box: box, leftEye: left, rightEye: right, nose: n, mouthLeft: ml, mouthRight: mr,
                               eyeOpenness: (openness(a) + openness(b)) / 2)
    }

    /// Height of an eye outline divided by its width, whatever way the head is tilted.
    static func openness(_ ps: [CGPoint]) -> Double {
        guard ps.count >= 4 else { return 0 }
        var far = (ps[0], ps[1]), best = 0.0
        for i in ps.indices { for j in ps.indices where j > i {
            let d = Double(hypot(ps[i].x - ps[j].x, ps[i].y - ps[j].y))
            if d > best { best = d; far = (ps[i], ps[j]) }
        } }
        guard best > 0.5 else { return 0 }
        let (ux, uy) = (Double(far.1.x - far.0.x) / best, Double(far.1.y - far.0.y) / best)
        let across = ps.map { Double($0.x - far.0.x) * -uy + Double($0.y - far.0.y) * ux }
        return ((across.max() ?? 0) - (across.min() ?? 0)) / best
    }
}
