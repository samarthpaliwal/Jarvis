import CoreAudio
import Foundation

/// Read-only CoreAudio helpers: which input device is the system default.
public enum AudioDeviceInfo {
    /// True when the default output is headphones (Bluetooth, or the built-in headphone jack), so the
    /// microphone cannot hear what Jarvis says. Built-in speakers, monitors, and anything unknown are false.
    public static func outputIsHeadphones() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return false }
        var transport = UInt32(0)
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        var tAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &tAddress, 0, nil, &tSize, &transport) == noErr else { return false }
        return isHeadphones(transport: transport, dataSource: outputDataSource(deviceID))
    }

    /// Pure decision, for tests. `dataSource` is the built-in output's source: 'hdpn' or 'ispk'.
    static func isHeadphones(transport: UInt32, dataSource: UInt32?) -> Bool {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return true
        case kAudioDeviceTransportTypeBuiltIn: return dataSource == 0x6864706E   // 'hdpn'
        default: return false
        }
    }

    private static func outputDataSource(_ deviceID: AudioDeviceID) -> UInt32? {
        var source = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &source) == noErr ? source : nil
    }

    public static func defaultInputDeviceName() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return "none" }
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, ptr)
        }
        return status == noErr ? (name as String) : "device \(deviceID)"
    }
}
