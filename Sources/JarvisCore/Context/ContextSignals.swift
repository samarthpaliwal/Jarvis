import AppKit
import CoreLocation
import CoreWLAN
import Foundation

/// Everything the mode detector looks at. Coordinates never leave this process.
public struct ContextSignals: Equatable, Sendable {
    public var latitude: Double?
    public var longitude: Double?
    public var locationAuthorized: Bool = false
    public var ssid: String?
    /// nil = unknown (no battery info yet)
    public var pluggedIn: Bool? = nil
    public var batteryPercent: Int?
    public var externalDisplays: Int = 0
    public var currentEventTitle: String?
    public var onHotspot: Bool = false
    public init() {}
}

/// Pure scoring: which mode do the signals point at? Unit-tested.
public enum ModeScorer {
    public struct Verdict: Equatable { public var modeID: String; public var score: Int; public var reasons: [String] }

    public static func distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        CLLocation(latitude: lat1, longitude: lon1).distance(from: CLLocation(latitude: lat2, longitude: lon2))
    }

    /// Places the signals currently match. Wi-Fi is a precise match (your dorm sits inside the
    /// campus geofence), so it scores higher than coordinates.
    public static func matchedPlaces(_ s: ContextSignals, places: [Place]) -> [(place: Place, byWifi: Bool)] {
        places.compactMap { place in
            if let ssid = s.ssid, place.wifiSSIDs.contains(where: { $0.caseInsensitiveCompare(ssid) == .orderedSame }) { return (place, true) }
            if let lat = s.latitude, let lon = s.longitude, let plat = place.latitude, let plon = place.longitude,
               distanceMeters(lat1: lat, lon1: lon, lat2: plat, lon2: plon) <= place.radiusMeters { return (place, false) }
            return nil
        }
    }

    public static func scores(_ s: ContextSignals, config: ModesConfig) -> [Verdict] {
        let matched = matchedPlaces(s, places: config.places)
        let here = Set(matched.map(\.place.id))
        let wifiHere = Set(matched.filter(\.byWifi).map(\.place.id))
        var verdicts: [Verdict] = []
        for mode in config.modes {
            var score = 0
            var reasons: [String] = []
            let t = mode.triggers
            let placeHits = t.places.filter { here.contains($0) }
            if !placeHits.isEmpty {
                let viaWifi = placeHits.contains { wifiHere.contains($0) }
                score += viaWifi ? 5 : 3
                reasons.append("at \(placeHits.joined(separator: "/"))\(viaWifi ? " (Wi-Fi)" : "")")
            }
            if let event = s.currentEventTitle?.lowercased(), t.calendarKeywords.contains(where: { event.contains($0.lowercased()) }) {
                score += 4; reasons.append("calendar: \(s.currentEventTitle ?? "")")
            }
            if let want = t.pluggedIn, let have = s.pluggedIn, want == have { score += 1; reasons.append(want ? "plugged in" : "on battery") }
            if let want = t.externalDisplay, s.pluggedIn != nil, want == (s.externalDisplays > 0) { score += 1; reasons.append(want ? "external display" : "no external display") }
            // Road: away from every known place, on battery or hotspot.
            if mode.id == "road", here.isEmpty, s.pluggedIn == false || s.onHotspot, s.locationAuthorized || s.ssid != nil {
                score += 2; reasons.append("away from known places")
            }
            if score > 0 { verdicts.append(Verdict(modeID: mode.id, score: score, reasons: reasons)) }
        }
        return verdicts
    }

    /// Highest score wins; `current` wins ties so modes don't flap.
    public static func best(_ s: ContextSignals, config: ModesConfig, current: String? = nil) -> Verdict? {
        let all = scores(s, config: config)
        guard let top = all.max(by: { $0.score < $1.score }) else { return nil }
        if let current, let cur = all.first(where: { $0.modeID == current }), cur.score == top.score { return cur }
        return top
    }
}

/// Collects signals on demand. Location is "when in use"; the app asks once and only reads a fix
/// every poll. No signal is ever sent to Claude except the resulting mode name.
@MainActor
public final class ContextDetector: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published public private(set) var signals = ContextSignals()
    @Published public private(set) var lastVerdict: ModeScorer.Verdict?

    public var onChange: ((ContextSignals) -> Void)?
    /// Fired when the home place is seen after ≥ 20 min away (or after waking from sleep at home).
    public var onArrivedHome: ((String) -> Void)?
    public var homePlaceIDs: () -> [String] = { ["home"] }
    public var homePlaces: () -> [Place] = { [] }
    private var lastHomeSeen: Date?
    private var wokeRecently = false
    private let launchedAt = Date()
    private let location = CLLocationManager()
    private let calendar: CalendarService
    private var timer: Timer?
    private var observers: [Any] = []
    private var fixContinuation: CheckedContinuation<CLLocation?, Never>?

    public init(calendar: CalendarService) {
        self.calendar = calendar
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    public func start(pollMinutes: Int) {
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(1, pollMinutes) * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(reason: "poll") }
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh(reason: "displays") }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.wokeRecently = true
                try? await Task.sleep(for: .seconds(5))
                await self?.refresh(reason: "wake")
                self?.wokeRecently = false
            }
        })
        Task { await refresh(reason: "start") }
    }

    public func refresh(reason: String) async {
        var s = ContextSignals()
        let b = SystemInfo.battery()
        s.pluggedIn = !b.onBattery
        s.batteryPercent = b.percent
        s.externalDisplays = max(0, NSScreen.screens.count - 1)
        s.ssid = Self.currentSSID()
        s.onHotspot = s.ssid.map { $0.lowercased().contains("iphone") || $0.lowercased().contains("hotspot") } ?? false
        s.locationAuthorized = [.authorizedAlways, .authorized].contains(location.authorizationStatus)
        if s.locationAuthorized, let fix = await currentFix() {
            s.latitude = fix.coordinate.latitude
            s.longitude = fix.coordinate.longitude
        }
        if let events = try? await calendar.events(from: Date().addingTimeInterval(-10 * 60), to: Date().addingTimeInterval(10 * 60)),
           let current = events.first(where: { !$0.isAllDay }) {
            s.currentEventTitle = current.title
        }
        let atHome = !ModeScorer.matchedPlaces(s, places: homePlaces()).isEmpty
        if atHome {
            // Launching the app while already at home is not an arrival.
            let awayLongEnough = lastHomeSeen.map { Date().timeIntervalSince($0) > 20 * 60 } ?? (Date().timeIntervalSince(launchedAt) > 120)
            if awayLongEnough || (wokeRecently && reason == "wake") {
                onArrivedHome?(awayLongEnough ? "home Wi-Fi after being away" : "woke from sleep at home")
            }
            lastHomeSeen = Date()
        }
        if s != signals {
            signals = s
            JarvisLog.info("Context (\(reason)): ssid=\(s.ssid ?? "-") plugged=\(s.pluggedIn.map(String.init) ?? "?") displays=\(s.externalDisplays) loc=\(s.latitude == nil ? "no" : "yes") event=\(s.currentEventTitle ?? "-")")
            onChange?(s)
        }
    }

    /// Current coordinates for "remember this place". Nil if location is unavailable.
    public func currentCoordinates() async -> (Double, Double)? {
        guard [.authorizedAlways, .authorized].contains(location.authorizationStatus), let fix = await currentFix() else { return nil }
        return (fix.coordinate.latitude, fix.coordinate.longitude)
    }

    private func currentFix() async -> CLLocation? {
        if let cached = location.location, Date().timeIntervalSince(cached.timestamp) < 120 { return cached }
        return await withCheckedContinuation { cont in
            fixContinuation?.resume(returning: nil)
            fixContinuation = cont
            location.startUpdatingLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, let c = self.fixContinuation else { return }
                self.fixContinuation = nil
                self.location.stopUpdatingLocation()
                c.resume(returning: self.location.location)
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let c = fixContinuation else { return }
            fixContinuation = nil
            location.stopUpdatingLocation()
            c.resume(returning: locations.last)
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard let c = fixContinuation else { return }
            fixContinuation = nil
            c.resume(returning: nil)
        }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            JarvisLog.info("Location authorization: \(manager.authorizationStatus.rawValue)")
            await refresh(reason: "authorization")
        }
    }

    nonisolated public static func currentSSID() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }
}
