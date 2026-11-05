import AppKit
import Foundation
import IOKit.ps

/// Tier 0: battery, memory pressure, disk, top apps, uptime.
public final class SystemStatusTool: JarvisTool {
    public let name = "system_status"
    public let description = "Read-only snapshot of the Mac: battery level and charging state, memory pressure, free disk space, top apps by memory, uptime, and the active audio input."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = ["type": "object", "properties": [:], "additionalProperties": false]

    public init() {}

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let snap = SystemInfo.snapshot()
        var lines = [
            "Battery: \(snap.batteryPercent.map { "\($0)%" } ?? "n/a") \(snap.charging ? "(charging)" : snap.onBattery ? "(on battery)" : "(plugged in)")",
            "Memory: \(snap.memoryPressure), \(snap.usedMemoryGB) of \(snap.totalMemoryGB) GB used",
            "Disk free: \(snap.diskFreeGB) GB",
            "Uptime: \(snap.uptimeHours) h",
            "Input device: \(AudioDeviceInfo.defaultInputDeviceName())",
            "Top apps by memory: " + snap.topApps.prefix(5).map { "\($0.name) \($0.memoryMB) MB" }.joined(separator: ", "),
        ]
        if snap.externalDisplays > 0 { lines.append("External displays: \(snap.externalDisplays)") }
        return ToolResult(lines.joined(separator: "\n"), card: .info(title: "System", lines: Array(lines.prefix(4))))
    }
}

/// Read-only system probes shared by several tools and the mode detector.
public enum SystemInfo {
    public struct AppUsage { public var name: String; public var memoryMB: Int; public var pid: Int32 }
    public struct Snapshot {
        public var batteryPercent: Int?
        public var charging: Bool
        public var onBattery: Bool
        public var memoryPressure: String
        public var usedMemoryGB: Int
        public var totalMemoryGB: Int
        public var diskFreeGB: Int
        public var uptimeHours: Int
        public var topApps: [AppUsage]
        public var externalDisplays: Int
    }

    public static func snapshot() -> Snapshot {
        let (pct, charging, onBattery) = battery()
        let total = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        let (pressure, usedGB) = memory()
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage).map { Int($0 / 1_073_741_824) } ?? 0
        return Snapshot(batteryPercent: pct, charging: charging, onBattery: onBattery, memoryPressure: pressure,
                        usedMemoryGB: usedGB, totalMemoryGB: total, diskFreeGB: free,
                        uptimeHours: Int(ProcessInfo.processInfo.systemUptime / 3600),
                        topApps: topApps(), externalDisplays: max(0, NSScreen.screens.count - 1))
    }

    public static func battery() -> (percent: Int?, charging: Bool, onBattery: Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false, false) }
        for ps in list {
            guard let info = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            let pct = info[kIOPSCurrentCapacityKey] as? Int
            let charging = info[kIOPSIsChargingKey] as? Bool ?? false
            let source = info[kIOPSPowerSourceStateKey] as? String
            return (pct, charging, source == kIOPSBatteryPowerValue)
        }
        return (nil, false, false)
    }

    static func memory() -> (pressure: String, usedGB: Int) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return ("unknown", 0) }
        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        let total = ProcessInfo.processInfo.physicalMemory
        let ratio = Double(used) / Double(total)
        let pressure = ratio > 0.9 ? "critical" : ratio > 0.75 ? "elevated" : "normal"
        return (pressure, Int(used / 1_073_741_824))
    }

    /// Top running GUI apps by resident memory (via `ps`, read-only).
    public static func topApps(limit: Int = 8) -> [AppUsage] {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let pids = Set(apps.map(\.processIdentifier))
        let out = Shell.readOnly("/bin/ps", ["-axo", "pid=,rss="])
        var usage: [AppUsage] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]), let rssKB = Int(parts[1]), pids.contains(pid),
                  let app = apps.first(where: { $0.processIdentifier == pid }) else { continue }
            usage.append(AppUsage(name: app.localizedName ?? "pid \(pid)", memoryMB: rssKB / 1024, pid: pid))
        }
        return Array(usage.sorted { $0.memoryMB > $1.memoryMB }.prefix(limit))
    }
}

/// Runs a read-only system binary with a timeout and captured output. Not the Tier 2 shell tool.
public enum Shell {
    public static func readOnly(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
