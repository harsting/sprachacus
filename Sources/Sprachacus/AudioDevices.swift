import CoreAudio
import Foundation

/// Aufzählung der Audiogeräte über Core Audio. Geräte werden über ihre UID
/// gemerkt, nicht über die numerische ID — die ID wechselt beim Neuanstecken.
enum AudioDevices {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    static func inputs() -> [Device] {
        all().filter { hasChannels($0, scope: kAudioObjectPropertyScopeInput) }
    }

    /// Name des Geräts zu einer UID, falls es (noch) angeschlossen ist.
    static func name(forUID uid: String) -> String? {
        inputs().first { $0.uid == uid }?.name
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputs().first { $0.uid == uid }?.id
    }

    /// Aktuell in den Systemeinstellungen gewähltes Ausgabegerät.
    static func defaultOutputName() -> String? {
        guard let id = defaultDevice(output: true) else { return nil }
        return name(of: id)
    }

    /// Grobe Erkennung interner Lautsprecher — dann hört das Mikrofon die
    /// Gegenseite mit und es braucht Echo-Unterdrückung.
    static func defaultOutputIsBuiltInSpeaker() -> Bool {
        guard let id = defaultDevice(output: true) else { return false }
        return transportType(of: id) == kAudioDeviceTransportTypeBuiltIn
    }

    // MARK: - Core-Audio-Details

    private static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = uid(of: id), let name = name(of: id) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    private static func hasChannels(_ device: Device, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device.id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector,
                                       of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }

    private static func uid(of id: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, of: id)
    }

    private static func name(of id: AudioDeviceID) -> String? {
        stringProperty(kAudioObjectPropertyName, of: id)
    }

    private static func transportType(of id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func defaultDevice(output: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: output ? kAudioHardwarePropertyDefaultOutputDevice
                              : kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }
}
