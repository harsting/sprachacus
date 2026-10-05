import CoreAudio
import Foundation
import IOKit

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

    /// Ist dieses Gerät im Mac eingebaut?
    static func isBuiltIn(_ id: AudioDeviceID) -> Bool {
        transportType(of: id) == kAudioDeviceTransportTypeBuiltIn
    }

    /// Ist der Deckel des MacBooks geschlossen (Betrieb am externen Bildschirm)?
    ///
    /// Wichtig, weil das eingebaute Mikrofon dann **digitale Stille** liefert —
    /// gemessen: 48.000 Abtastwerte pro Sekunde, alle exakt null. Core Audio
    /// meldet das Gerät weiterhin als lebendig, nicht stumm und mit normalem
    /// Eingangspegel; es bleibt sogar als Systemstandard wählbar. Ohne diese
    /// Prüfung nimmt Sprachacus stundenlang nichts auf, ohne es zu merken.
    static func lidIsClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                          kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool else { return false }
        return value
    }

    /// Aktuell in den Systemeinstellungen gewähltes Eingabegerät.
    static func defaultInputID() -> AudioDeviceID? { defaultDevice(output: false) }

    /// Name eines Geräts zu seiner numerischen ID.
    static func name(forID id: AudioDeviceID) -> String? { name(of: id) }

    /// Beobachtet, welches Eingabegerät das System benutzt und ob Geräte
    /// kommen oder gehen.
    ///
    /// Nötig, weil `AVAudioEngineConfigurationChange` den Wechsel des
    /// Standard-Eingabegeräts nicht zuverlässig meldet: Die Engine bleibt am
    /// alten Gerät hängen, ohne dass es auffällt. Genau so blieb am 05.10. in
    /// einem Meeting die eigene Stimme komplett aus — gewechselt wurde auf ein
    /// Tischmikrofon, aufgenommen wurde weiter das alte, stumme Gerät.
    static func observeInputChanges(_ handler: @escaping () -> Void) -> Any {
        InputChangeObserver(handler: handler)
    }

    /// Hält die Core-Audio-Beobachter und räumt sie beim Freigeben auf.
    private final class InputChangeObserver {
        private let block: AudioObjectPropertyListenerBlock
        private var addresses: [AudioObjectPropertyAddress] = [
            AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
        ]

        init(handler: @escaping () -> Void) {
            block = { _, _ in handler() }
            for index in addresses.indices {
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                    &addresses[index], DispatchQueue.main, block)
            }
        }

        deinit {
            for index in addresses.indices {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                       &addresses[index], DispatchQueue.main, block)
            }
        }
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
