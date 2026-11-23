import CryptoKit
import Foundation

/// The enrolled face: numbers only, never a picture. Biometric data: one encrypted file on this Mac,
/// never logged, never sent anywhere.
public struct FaceTemplate: Codable, Equatable, Sendable {
    public var version = 1
    public var model: String
    public var embeddings: [[Float]]
    public var centroid: [Float]
    public var createdAt: Date
    /// How alike the enrollment pictures were to the final template (lowest and average).
    public var selfScoreMin: Double
    public var selfScoreMean: Double

    /// How alike a face is to the enrolled one: the average of "like the overall template" and "like the
    /// three closest enrollment pictures", so one lucky angle is not enough.
    public func score(_ embedding: [Float]) -> Double {
        let overall = FaceMath.cosine(embedding, centroid)
        let nearest = embeddings.map { FaceMath.cosine(embedding, $0) }.sorted(by: >).prefix(3)
        guard !nearest.isEmpty else { return overall }
        return (overall + nearest.reduce(0, +) / Double(nearest.count)) / 2
    }

    /// Builds a template from enrollment embeddings, refusing a set that does not agree with itself.
    public static func build(_ embeddings: [[Float]], model: String, minimumFrames: Int = 15, minimumAgreement: Double = 0.5,
                             now: Date = Date()) throws -> FaceTemplate {
        guard embeddings.count >= minimumFrames else { throw FaceError.tooFewFrames(embeddings.count) }
        let centroid = FaceMath.centroid(embeddings)
        let scores = embeddings.map { FaceMath.cosine($0, centroid) }
        let low = scores.min() ?? 0
        guard low >= minimumAgreement else { throw FaceError.inconsistent(low) }
        return FaceTemplate(model: model, embeddings: embeddings, centroid: centroid, createdAt: now,
                            selfScoreMin: low, selfScoreMean: scores.reduce(0, +) / Double(scores.count))
    }
}

/// Reads and writes the template, encrypted with AES-256-GCM. The key is not in the file or the folder:
/// it lives in the Keychain behind Touch ID, with Jarvis's other secrets. Without the key the file is noise.
public final class FaceTemplateStore: @unchecked Sendable {
    public static let keyAccount = "FACE_TEMPLATE_KEY"
    public let url: URL
    private let readKey: @Sendable () -> String?
    private let writeKey: @Sendable (String) throws -> Void
    private let deleteKey: @Sendable () -> Void

    public static var defaultURL: URL {
        ConfigLocator.userConfigDirectory.deletingLastPathComponent().appendingPathComponent("faceprint/face.bin")
    }

    public init(url: URL = FaceTemplateStore.defaultURL,
                readKey: @escaping @Sendable () -> String? = { SecretVault.shared.read(FaceTemplateStore.keyAccount) },
                writeKey: @escaping @Sendable (String) throws -> Void = { try SecretVault.shared.write($0, account: FaceTemplateStore.keyAccount) },
                deleteKey: @escaping @Sendable () -> Void = { SecretVault.shared.delete(FaceTemplateStore.keyAccount) }) {
        self.url = url; self.readKey = readKey; self.writeKey = writeKey; self.deleteKey = deleteKey
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    private func key(createIfMissing: Bool) throws -> SymmetricKey {
        if let text = readKey(), let data = Data(base64Encoded: text), data.count == 32 { return SymmetricKey(data: data) }
        guard createIfMissing else { throw FaceError.keyUnavailable }
        let fresh = SymmetricKey(size: .bits256)
        try writeKey(fresh.withUnsafeBytes { Data($0).base64EncodedString() })
        return fresh
    }

    /// Nil when nothing is enrolled. Throws when a template exists but cannot be opened: callers lock.
    public func load() throws -> FaceTemplate? {
        guard exists else { return nil }
        let key = try key(createIfMissing: false)
        do {
            let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            return try d.decode(FaceTemplate.self, from: AES.GCM.open(box, using: key))
        } catch { throw FaceError.templateUnreadable }
    }

    public func save(_ template: FaceTemplate) throws {
        // A template that exists is only ever replaced with its own key; a new one gets a new key.
        let key = try key(createIfMissing: !exists)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        guard let sealed = try AES.GCM.seal(e.encode(template), using: key).combined else { throw FaceError.templateUnreadable }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try sealed.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
        deleteKey()
    }
}
