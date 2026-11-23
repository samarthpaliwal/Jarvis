import AppKit
import Foundation

/// The phone app: a handful of static files served by the remote API itself, so there is nothing to host
/// anywhere else. The files live in `Resources/WebApp` (which is also what a Capacitor wrapper would ship).
///
/// These files are the only thing the API hands out without a token: they are the same for everyone and
/// contain no data. Everything they do afterwards goes through the token-checked routes.
public enum WebApp {
    static let files: [String: (name: String, type: String)] = [
        "/": ("index.html", "text/html; charset=utf-8"),
        "/index.html": ("index.html", "text/html; charset=utf-8"),
        "/app.js": ("app.js", "text/javascript; charset=utf-8"),
        "/app.css": ("app.css", "text/css; charset=utf-8"),
        "/sw.js": ("sw.js", "text/javascript; charset=utf-8"),
        "/manifest.webmanifest": ("manifest.webmanifest", "application/manifest+json"),
    ]
    static let icons: [String: Int] = ["/icon-192.png": 192, "/icon-512.png": 512, "/apple-touch-icon.png": 180]

    /// Nothing but this page's own files may load or be contacted; it cannot be framed.
    static let contentSecurityPolicy = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; manifest-src 'self'; worker-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    public static var directory: URL? { Bundle.module.url(forResource: "WebApp", withExtension: nil) }

    public static func isShellPath(_ path: String) -> Bool { files[path] != nil || icons[path] != nil }

    public static func response(for path: String) -> HTTPResponse? {
        var headers = ["Content-Security-Policy": contentSecurityPolicy, "Referrer-Policy": "no-referrer", "X-Frame-Options": "DENY",
                       "Permissions-Policy": "microphone=(self), camera=(), geolocation=()"]
        if let size = icons[path] {
            headers["Content-Type"] = "image/png"
            return HTTPResponse(status: 200, headers: headers, body: icon(size: size))
        }
        guard let file = files[path], let dir = directory, let data = try? Data(contentsOf: dir.appendingPathComponent(file.name)) else { return nil }
        headers["Content-Type"] = file.type
        return HTTPResponse(status: 200, headers: headers, body: data)
    }

    private static let iconLock = NSLock()
    private nonisolated(unsafe) static var iconCache: [Int: Data] = [:]

    /// The app icon, drawn rather than shipped: a dark tile with a ring, full-bleed so it can be masked.
    public static func icon(size: Int) -> Data {
        iconLock.lock(); defer { iconLock.unlock() }
        if let cached = iconCache[size] { return cached }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let s = CGFloat(size)
        NSColor(srgbRed: 0.043, green: 0.051, blue: 0.071, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: s, height: s)).fill()
        let accent = NSColor(srgbRed: 0.353, green: 0.784, blue: 0.980, alpha: 1)
        func ring(_ radius: CGFloat, width: CGFloat, alpha: CGFloat) {
            let p = NSBezierPath(ovalIn: NSRect(x: s / 2 - radius, y: s / 2 - radius, width: radius * 2, height: radius * 2))
            p.lineWidth = width
            accent.withAlphaComponent(alpha).setStroke()
            p.stroke()
        }
        ring(s * 0.30, width: s * 0.035, alpha: 1)
        ring(s * 0.21, width: s * 0.018, alpha: 0.55)
        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: s * 0.5 - s * 0.085, y: s * 0.5 - s * 0.085, width: s * 0.17, height: s * 0.17)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = rep.representation(using: .png, properties: [:]) ?? Data()
        iconCache[size] = png
        return png
    }
}

/// Pairing a phone without typing a 47-character token: the Mac shows a six-digit code for two minutes,
/// the phone sends it, and gets its own token back.
///
/// One code at a time. A handful of wrong guesses cancels it, so the odds of guessing it are a few in a million,
/// and only from a device already on the tailnet.
public final class PairingCodes: @unchecked Sendable {
    public struct Offer: Equatable, Sendable {
        public var code: String
        public var name: String
        public var expires: Date
    }

    public var lifetime: TimeInterval
    public var maxAttempts: Int
    private let lock = NSLock()
    private var offer: Offer?
    private var attempts = 0

    public init(lifetime: TimeInterval = 120, maxAttempts: Int = 5) { self.lifetime = lifetime; self.maxAttempts = maxAttempts }

    /// Starts pairing a device. Replaces any code still open.
    public func begin(name: String, now: Date = Date()) -> Offer {
        var generator = SystemRandomNumberGenerator()      // cryptographically secure on Apple platforms
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000, using: &generator))
        let o = Offer(code: code, name: name, expires: now.addingTimeInterval(lifetime))
        lock.lock(); offer = o; attempts = 0; lock.unlock()
        return o
    }

    public func isActive(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let o = offer, o.expires <= now { offer = nil }
        return offer != nil
    }

    /// The device name when the code is right. A right code works once; too many wrong ones cancel it.
    public func redeem(_ presented: String, now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let o = offer, o.expires > now else { offer = nil; return nil }
        let a = Array(o.code.utf8), b = Array(presented.utf8)
        var diff = UInt8(a.count == b.count ? 0 : 1)
        for i in 0..<min(a.count, b.count) { diff |= a[i] ^ b[i] }
        if diff == 0 { offer = nil; return o.name }
        attempts += 1
        if attempts >= maxAttempts { offer = nil }
        return nil
    }

    public func cancel() { lock.lock(); offer = nil; lock.unlock() }
}
