import AudioToolbox
import CoreAudio
import Foundation

/// Tier 1: output volume / mute on the default output device. Undoable.
public final class SetVolumeTool: JarvisTool {
    public let name = "set_volume"
    public let description = "Set the Mac's output volume (0–100) or mute/unmute. Reversible."
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": [
            "percent": ["type": "integer", "minimum": 0, "maximum": 100],
            "mute": ["type": "boolean"],
        ],
        "additionalProperties": false,
    ]

    public init() {}

    public func preview(for input: JSONObject) -> String {
        if let m = input.bool("mute") { return m ? "mute" : "unmute" }
        return "set volume to \(input.int("percent") ?? 0)%"
    }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let before = AudioOutput.volume()
        let beforeMute = AudioOutput.isMuted()
        if let m = input.bool("mute") {
            try AudioOutput.setMuted(m)
            await context.undo.push(.init(description: m ? "muted" : "unmuted") { try AudioOutput.setMuted(beforeMute); return "Restored mute state." })
            return ToolResult(m ? "Muted." : "Unmuted.", summary: m ? "Muted" : "Unmuted")
        }
        guard let pct = input.int("percent") else { return .error("Give percent or mute.") }
        try AudioOutput.setVolume(Float(max(0, min(100, pct))) / 100)
        if beforeMute, pct > 0 { try? AudioOutput.setMuted(false) }
        await context.undo.push(.init(description: "volume to \(pct)%") {
            try AudioOutput.setVolume(before); return "Volume back to \(Int(before * 100))%."
        })
        return ToolResult("Volume set to \(pct)%.", summary: "Volume \(pct)%")
    }
}

public enum AudioOutput {
    struct AudioError: LocalizedError { let status: OSStatus; var errorDescription: String? { "CoreAudio error \(status)" } }

    static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr ? id : nil
    }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    public static func volume() -> Float {
        guard let dev = defaultOutput() else { return 0 }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : 0
    }

    public static func setVolume(_ value: Float) throws {
        guard let dev = defaultOutput() else { throw AudioError(status: -1) }
        var v = Float32(max(0, min(1, value)))
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        let s = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        guard s == noErr else { throw AudioError(status: s) }
    }

    public static func isMuted() -> Bool {
        guard let dev = defaultOutput() else { return false }
        var m: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyMute)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr && m == 1
    }

    public static func setMuted(_ muted: Bool) throws {
        guard let dev = defaultOutput() else { throw AudioError(status: -1) }
        var m: UInt32 = muted ? 1 : 0
        var addr = address(kAudioDevicePropertyMute)
        let s = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        guard s == noErr else { throw AudioError(status: s) }
    }
}
