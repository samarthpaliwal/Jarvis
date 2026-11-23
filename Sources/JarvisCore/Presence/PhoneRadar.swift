import CoreBluetooth
import Foundation

/// Whether the phone is near the Mac, worked out from how strong its Bluetooth signal is. No system calls
/// in here, so the rules are tested: a strong signal means near, a weak one for a while or silence for a
/// while means away, and the two thresholds are apart so it does not flap at the edge of the room.
public struct PresenceTracker: Equatable, Sendable {
    public enum State: String, Sendable { case unknown, near, away }
    public struct Settings: Equatable, Sendable {
        /// Signal at or above this is "near" (about the same room).
        public var nearRSSI: Double = -72
        /// Signal at or below this, for `weakSeconds`, is "away".
        public var awayRSSI: Double = -88
        public var weakSeconds: TimeInterval = 45
        /// Not heard at all for this long is "away".
        public var lostSeconds: TimeInterval = 90
        /// Strong readings needed in a row before "near", so one stray packet does not count.
        public var nearReadings = 2
        /// The signal is averaged over about this many seconds, so one odd reading moves it very little.
        public var smoothingSeconds: TimeInterval = 4
        public init() {}
    }

    public var settings = Settings()
    public private(set) var state: State = .unknown
    public private(set) var smoothed: Double?
    public private(set) var lastSeen: Date?
    private var weakSince: Date?
    private var strongRun = 0

    public init(settings: Settings = Settings()) { self.settings = settings }

    /// One Bluetooth sighting. Returns the new state if it changed.
    public mutating func sighting(rssi: Double, at now: Date) -> State? {
        // 127 is CoreBluetooth's "no reading"; positive values are noise.
        guard rssi < 0, rssi > -110 else { return nil }
        // A long silence makes the old average meaningless.
        if let seen = lastSeen, now.timeIntervalSince(seen) > 20 { smoothed = nil }
        // Time-based averaging: a reading counts for more the longer it has been since the last one.
        let gap = lastSeen.map { max(0.05, now.timeIntervalSince($0)) } ?? 0
        let weight = settings.smoothingSeconds > 0 ? 1 - exp(-gap / settings.smoothingSeconds) : 1
        smoothed = smoothed.map { $0 * (1 - weight) + rssi * weight } ?? rssi
        lastSeen = now
        guard let s = smoothed else { return nil }
        if s >= settings.nearRSSI {
            weakSince = nil
            strongRun += 1
            if state != .near, strongRun >= settings.nearReadings { state = .near; return .near }
        } else {
            strongRun = 0
            if s <= settings.awayRSSI {
                if weakSince == nil { weakSince = now }
            } else { weakSince = nil }
        }
        return check(now)
    }

    /// Called on a timer: silence is information too.
    public mutating func tick(at now: Date) -> State? { check(now) }

    private mutating func check(_ now: Date) -> State? {
        guard state != .away else { return nil }
        let lost = lastSeen.map { now.timeIntervalSince($0) >= settings.lostSeconds } ?? false
        let weak = weakSince.map { now.timeIntervalSince($0) >= settings.weakSeconds } ?? false
        // "unknown" only becomes "away" once the phone has been heard at least once, or never shows up.
        guard lost || weak else { return nil }
        state = .away; strongRun = 0
        return .away
    }

    /// A rough distance in metres. Walls and pockets change it a lot; it is a guide, not a ruler.
    public static func metres(rssi: Double) -> Double { pow(10, (-59 - rssi) / 25) }

    public static func describe(rssi: Double) -> String {
        let m = metres(rssi: rssi)
        switch m {
        case ..<1: return "right here"
        case ..<4: return "about \(Int(m.rounded())) m away"
        case ..<10: return "in the next room or so (about \(Int(m.rounded())) m)"
        default: return "far (10 m or more)"
        }
    }
}

public struct BluetoothSighting: Equatable, Sendable {
    public var id: UUID
    public var name: String?
    public var rssi: Double
    public var isApple: Bool
    public var at: Date
    /// The first Apple message type in the advertisement (0x10 "nearby", 0x0C handoff, 0x12 Find My…).
    public var appleType: UInt8? = nil
}

/// Listens for Bluetooth advertisements. It never connects to anything and never sends anything.
final class BluetoothScanner: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager?
    var onSighting: ((BluetoothSighting) -> Void)?
    var onState: ((String) -> Void)?
    private(set) var stateText = "off"

    func start() {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) } else { scan() }
    }

    func stop() {
        central?.stopScan()
        central = nil
        stateText = "off"
    }

    private func scan() {
        guard let c = central, c.state == .poweredOn, !c.isScanning else { return }
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: stateText = "listening"; scan()
        case .poweredOff: stateText = "Bluetooth is off"
        case .unauthorized: stateText = "not allowed (System Settings → Privacy & Security → Bluetooth)"
        case .unsupported: stateText = "this Mac has no Bluetooth"
        default: stateText = "starting"
        }
        onState?(stateText)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let maker = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        // Apple's company number, 0x004C, leads every iPhone, Watch, and AirPods advertisement.
        let apple = (maker?.count ?? 0) >= 2 && maker?[0] == 0x4C && maker?[1] == 0x00
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        onSighting?(BluetoothSighting(id: peripheral.identifier, name: name, rssi: RSSI.doubleValue, isApple: apple, at: Date(),
                                      appleType: apple && (maker?.count ?? 0) > 2 ? maker?[2] : nil))
    }
}

/// The phone as a radar: is Sam (his phone) near the Mac. Off until switched on in the menu, and it only
/// listens once a phone has been chosen or is being chosen.
@MainActor
public final class PhoneRadar: ObservableObject {
    public static let enabledKey = "jarvis.radar.enabled"
    public static let phoneKey = "jarvis.radar.phoneID"
    public static let nameKey = "jarvis.radar.phoneName"

    @Published public private(set) var tracker = PresenceTracker()
    public private(set) var phoneID: UUID? = UserDefaults.standard.string(forKey: PhoneRadar.phoneKey).flatMap(UUID.init)
    public private(set) var phoneName: String = UserDefaults.standard.string(forKey: PhoneRadar.nameKey) ?? "phone"
    public var enabled: Bool = UserDefaults.standard.bool(forKey: PhoneRadar.enabledKey) {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); enabled ? start() : stop() }
    }
    /// Told when the phone comes near or goes away (never for the first reading after launch being "near").
    public var onChange: ((PresenceTracker.State, _ previous: PresenceTracker.State) -> Void)?

    private let scanner = BluetoothScanner()
    private var timer: Timer?
    /// Everything heard lately, for choosing the phone.
    private var nearby: [UUID: BluetoothSighting] = [:]
    private var choosing = false

    public init() {
        scanner.onSighting = { [weak self] s in Task { @MainActor in self?.heard(s) } }
    }

    public var bluetoothState: String { scanner.stateText }

    /// What the owner lock needs to know: is the chosen phone near right now, and if not, why not.
    /// Anything other than a clear "near" counts as not near, including Bluetooth being off.
    public struct Check: Equatable, Sendable {
        public var near: Bool
        public var why: String
        public init(near: Bool, why: String) { self.near = near; self.why = why }
    }
    public var check: Check {
        guard phoneID != nil else { return Check(near: false, why: "no phone has been chosen (menu → Phone Radar → Set My Phone)") }
        guard enabled else { return Check(near: false, why: "the phone radar is switched off") }
        guard scanner.stateText == "listening" else { return Check(near: false, why: "Bluetooth is not available (\(scanner.stateText))") }
        switch tracker.state {
        case .near: return Check(near: true, why: "\(phoneName) is near")
        case .away: return Check(near: false, why: "\(phoneName) is not nearby")
        case .unknown: return Check(near: false, why: "\(phoneName) has not been heard yet")
        }
    }

    /// Thresholds and timings from the settings file.
    public func apply(_ settings: PresenceTracker.Settings) {
        guard tracker.settings != settings else { return }
        tracker.settings = settings
    }

    public var statusLine: String {
        guard enabled else { return "Phone radar: off" }
        guard phoneID != nil else { return "Phone radar: no phone chosen yet" }
        if scanner.stateText != "listening" { return "Phone radar: \(scanner.stateText)" }
        switch tracker.state {
        case .unknown: return "\(phoneName): looking for it…"
        case .away: return "\(phoneName): away"
        case .near: return "\(phoneName): near, \(tracker.smoothed.map(PresenceTracker.describe) ?? "")"
        }
    }

    public func start() {
        guard enabled || choosing else { return }
        scanner.start()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }

    public func stop() {
        guard !choosing else { return }
        scanner.stop(); timer?.invalidate(); timer = nil
        tracker = PresenceTracker(); nearby = [:]
    }

    private func heard(_ s: BluetoothSighting) {
        nearby[s.id] = s
        if survey != nil, s.isApple, s.rssi < 0 {
            var row = survey?[s.id] ?? SurveyRow(id: s.id, name: s.name, count: 0, meanRSSI: 0, types: [])
            row.meanRSSI = (row.meanRSSI * Double(row.count) + s.rssi) / Double(row.count + 1)
            row.count += 1
            if let n = s.name { row.name = n }
            if let t = s.appleType { row.types.insert(t) }
            survey?[s.id] = row
        }
        guard enabled, s.id == phoneID else { return }
        let before = tracker.state
        if let now = tracker.sighting(rssi: s.rssi, at: s.at) { changed(to: now, from: before) }
    }

    private func tick() {
        let cutoff = Date().addingTimeInterval(-30)
        nearby = nearby.filter { $0.value.at > cutoff }
        guard enabled, phoneID != nil else { return }
        let before = tracker.state
        if let now = tracker.tick(at: Date()) { changed(to: now, from: before) }
    }

    private func changed(to now: PresenceTracker.State, from before: PresenceTracker.State) {
        JarvisLog.info("Phone radar: \(phoneName) \(before.rawValue) → \(now.rawValue)\(tracker.smoothed.map { " (signal \(Int($0)))" } ?? "")")
        onChange?(now, before)
    }

    /// The strongest Apple device heard in the last few seconds: the phone, if it is held against the Mac.
    nonisolated public static func closest(_ sightings: [BluetoothSighting], now: Date, minimumRSSI: Double = -55) -> BluetoothSighting? {
        let close = sightings.filter { $0.isApple && now.timeIntervalSince($0.at) < 6 && $0.rssi >= minimumRSSI && $0.rssi < 0 }
        // macOS names the owner's own devices (same Apple account). An iPhone it can name beats headphones
        // or a watch that merely happen to be closer.
        let phones = close.filter { $0.name?.localizedCaseInsensitiveContains("iPhone") ?? false }
        return (phones.isEmpty ? close : phones).max { $0.rssi < $1.rssi }
    }

    /// Listen for a few seconds and hand back the closest Apple device.
    public func findClosest(seconds: Double = 6) async -> BluetoothSighting? {
        choosing = true
        nearby = [:]
        start()
        try? await Task.sleep(for: .seconds(seconds))
        choosing = false
        let found = Self.closest(Array(nearby.values), now: Date())
        if !enabled { stop() }
        return found
    }

    /// One device heard during a survey.
    public struct SurveyRow: Equatable, Sendable {
        public var id: UUID
        public var name: String?
        public var count: Int
        public var meanRSSI: Double
        public var types: Set<UInt8>
    }
    private var survey: [UUID: SurveyRow]?

    /// Listen for a while and report every Apple device heard: for working out how to recognise the phone.
    public func runSurvey(seconds: Double) async -> [SurveyRow] {
        choosing = true
        survey = [:]
        start()
        try? await Task.sleep(for: .seconds(seconds))
        choosing = false
        let rows = (survey ?? [:]).values.sorted { $0.meanRSSI > $1.meanRSSI }
        survey = nil
        if !enabled { stop() }
        return rows
    }

    public func choose(_ s: BluetoothSighting) {
        phoneID = s.id
        phoneName = s.name ?? "My phone"
        UserDefaults.standard.set(s.id.uuidString, forKey: Self.phoneKey)
        UserDefaults.standard.set(phoneName, forKey: Self.nameKey)
        tracker = PresenceTracker()
        JarvisLog.info("Phone radar: phone chosen (\(phoneName))")
        if !enabled { enabled = true }
    }
}
