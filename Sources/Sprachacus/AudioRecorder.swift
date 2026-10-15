import AVFoundation
import Accelerate
import CoreAudio

/// Captures microphone audio via AVAudioEngine. One input tap feeds both the
/// transcriber (raw buffers) and the overlay waveform (RMS level).
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var deviceObserver: Any?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onLevel: ((Float) -> Void)?
    /// Wunschreihenfolge der Mikrofone (UIDs), beste zuerst.
    private var preferredUIDs: [String] = []
    /// Geräte, die in dieser Sitzung nachweislich keinen Ton geliefert haben.
    private var silentDeviceIDs: Set<AudioDeviceID> = []
    /// Ob seit dem Start der laufenden Engine irgendein Ton ankam.
    private var sawSignal = false
    private var signalProbe: DispatchWorkItem?
    /// Gerät, auf das die laufende Engine gestartet wurde.
    ///
    /// Bewusst das *gewünschte* Gerät und nicht das, was die Engine
    /// zurückmeldet: Folgt sie dem Systemstandard, hängt sie an einem privaten
    /// Sammelgerät („CADefaultDeviceAggregate-…"), dessen ID nie einem echten
    /// Gerät entspricht. Ein Vergleich damit hielte jeden Zustand für falsch
    /// und würde die Engine endlos neu starten.
    private var activeDeviceID: AudioDeviceID?
    /// Verzögerte Prüfung nach einer Gerätemeldung.
    private var pendingDeviceCheck: DispatchWorkItem?

    /// So lange wird auf das erste Lebenszeichen eines Mikrofons gewartet.
    /// Ein funktionierendes Gerät liefert innerhalb von Millisekunden.
    private static let probeDelay: TimeInterval = 1.5

    /// Bis dahin werden Meldungen über geänderte Audio-Konfiguration
    /// ignoriert.
    ///
    /// Nötig, weil das Umstellen des Eingabegeräts selbst so eine Meldung
    /// auslöst: Ohne diese Sperre startete die Engine sich in einer Schleife
    /// immer wieder neu (gemessen 21 Neustarts in acht Sekunden) und es kam
    /// überhaupt kein Ton mehr an.
    private var ignoreConfigurationChangesUntil = DispatchTime.now()
    private var pendingConfigurationRestart: DispatchWorkItem?

    /// Meldet nennenswerte Ereignisse (gewähltes Gerät, Wechsel, Fehlschläge)
    /// nach außen. Im Meeting landen sie im Protokoll neben dem Transkript —
    /// NSLog ist aus dieser App nicht auslesbar.
    var onEvent: ((String) -> Void)?

    /// Name des Geräts, von dem gerade aufgenommen wird.
    var currentDeviceName: String? { activeDeviceID.flatMap { AudioDevices.name(forID: $0) } }

    /// Läuft die Aufnahme über ein im Mac eingebautes Mikrofon? Bei
    /// geschlossenem Deckel liefert das keinen Ton.
    var isUsingBuiltInMicrophone: Bool { activeDeviceID.map { AudioDevices.isBuiltIn($0) } ?? false }

    /// Dasselbe für das *zuletzt* benutzte Gerät — bleibt nach `stop()`
    /// erhalten, damit sich ein leeres Ergebnis hinterher noch erklären lässt.
    private(set) var lastDeviceWasBuiltIn = false

    /// Reports a failed recovery after an audio route change (e.g. AirPods
    /// connected mid-recording). The mic is dead at that point.
    var onRestartFailed: ((Error) -> Void)?

    var isRunning: Bool { engine != nil }

    /// - Parameter preferredUIDs: Wunschreihenfolge der Mikrofone, beste
    ///   zuerst. Leer = Systemstandard. Benutzt wird das erste Gerät, das
    ///   angeschlossen ist und tatsächlich Ton liefert.
    ///
    /// Bewusst OHNE Apples Voice Processing: Es schaltet das systemweite
    /// Ausgabegerät um (gemessen: von AirPods auf die internen Lautsprecher)
    /// und senkt den Ton anderer Apps auf null — mitten im Meeting hört man
    /// die Gegenseite dann nicht mehr. Das Echo wird stattdessen auf
    /// Transkriptebene herausgefiltert (siehe MeetingController).
    func start(preferredUIDs: [String] = [],
               onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
               onLevel: @escaping (Float) -> Void) throws {
        stop()
        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.preferredUIDs = preferredUIDs
        self.silentDeviceIDs = []
        try startEngine()
        scheduleSignalProbe()

        // Route changes (headphones in/out, sample-rate switch) invalidate the
        // tap format. React outside the notification handler — tearing the
        // engine down inside it is not allowed.
        //
        // Bewusst OHNE `queue: .main`: Mit einer Warteschlange liefert
        // NotificationCenter über eine NSOperation aus und der *Absender*
        // wartet, bis sie fertig ist. Die Meldung kommt aber aus der internen
        // Warteschlange der AVAudioEngine — und deren Freigabe wartet
        // umgekehrt per dispatch_sync auf genau diese Warteschlange. Ergebnis
        // war ein Ringschluss, der den Hauptthread für immer anhielt: Das
        // Overlay blieb stehen und ließ sich nicht mehr schließen. Hier wird
        // die Meldung also auf dem Absender-Thread angenommen und nur die
        // Arbeit auf den Hauptthread verschoben.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.scheduleConfigurationRestart()
        }

        // Zusätzlich direkt an Core Audio horchen: Wechselt der Nutzer das
        // Eingabegerät in den Systemeinstellungen oder im Meeting-Programm,
        // bleibt die Engine sonst am alten Gerät — und nimmt im Zweifel
        // Stille auf, ohne dass es jemand merkt.
        deviceObserver = AudioDevices.observeInputChanges { [weak self] in
            self?.scheduleDeviceCheck()
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        deviceObserver = nil
        pendingDeviceCheck?.cancel()
        pendingDeviceCheck = nil
        signalProbe?.cancel()
        signalProbe = nil
        pendingConfigurationRestart?.cancel()
        pendingConfigurationRestart = nil
        teardownEngine()
        onBuffer = nil
        onLevel = nil
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Must happen before the format is read and before the engine starts.
        if let chosen = desiredDeviceID() {
            setInputDevice(chosen, on: input)
        }

        // Bewusst `inputFormat`: Das ist das Format der *Hardware*.
        // `outputFormat` liefert das, was der Knoten beim ersten Zugriff
        // gespeichert hat — und das ist noch das des vorherigen Geräts.
        // Gemessen: Mit dem alten Weg meldete die App „RODE NT-USB,
        // 24000 Hz, 1 Kanal" (das Format der AirPods) und bekam null Puffer.
        let hardware = input.inputFormat(forBus: 0)
        let cached = input.outputFormat(forBus: 0)
        if hardware.sampleRate != cached.sampleRate || hardware.channelCount != cached.channelCount {
            onEvent?("Formatabweichung: Hardware \(Int(hardware.sampleRate)) Hz/\(hardware.channelCount) ≠ Knoten \(Int(cached.sampleRate)) Hz/\(cached.channelCount) — es gilt die Hardware")
        }
        let format = hardware.sampleRate > 0 ? hardware : cached
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let level = Self.rms(buffer)
            if level > 0 { self.sawSignal = true }
            self.onLevel?(level)
            self.onBuffer?(buffer)
        }
        sawSignal = false
        ignoreConfigurationChangesUntil = DispatchTime.now() + 1.5
        engine.prepare()
        try engine.start()
        self.engine = engine
        activeDeviceID = desiredDeviceID()
        lastDeviceWasBuiltIn = isUsingBuiltInMicrophone
        onEvent?("Mikrofon aktiv: \(currentDeviceName ?? "unbekannt") — \(Int(format.sampleRate)) Hz, \(format.channelCount) Kanal(e)")
    }

    /// Die Kandidaten in der Reihenfolge, in der sie probiert werden:
    /// erst die Wunschliste, dann der Systemstandard, dann der Rest.
    ///
    /// Das eingebaute Mikrofon kommt bei geschlossenem Deckel ganz zuletzt —
    /// es liefert dann gemessen nur Nullen.
    private func candidateIDs() -> [AudioDeviceID] {
        let connected = AudioDevices.inputs()
        var ordered: [AudioDeviceID] = []
        for uid in preferredUIDs {
            if let device = connected.first(where: { $0.uid == uid }) { ordered.append(device.id) }
        }
        if let standard = AudioDevices.defaultInputID(),
           connected.contains(where: { $0.id == standard }) {
            ordered.append(standard)
        }
        // Nur echte Mikrofone als automatische Ausweichmöglichkeit. Virtuelle
        // Geräte liefern fremden Ton — „Microsoft Teams Audio" den Systemton —
        // und würden als eigene Stimme im Transkript landen. Steht so ein
        // Gerät ausdrücklich in der Wunschliste, wird es oben trotzdem
        // berücksichtigt.
        ordered.append(contentsOf: connected.map(\.id).filter { !AudioDevices.isVirtual($0) })

        var seen = Set<AudioDeviceID>()
        var unique = ordered.filter { seen.insert($0).inserted }
        if AudioDevices.lidIsClosed() {
            let builtIn = unique.filter { AudioDevices.isBuiltIn($0) }
            unique = unique.filter { !AudioDevices.isBuiltIn($0) } + builtIn
        }
        return unique
    }

    /// Welches Gerät die Engine benutzen *soll*: der beste Kandidat, der in
    /// dieser Sitzung noch nicht als stumm aufgefallen ist.
    private func desiredDeviceID() -> AudioDeviceID? {
        let candidates = candidateIDs()
        return candidates.first { !silentDeviceIDs.contains($0) } ?? candidates.first
    }

    /// Prüft kurz nach dem Start, ob überhaupt Ton ankommt — und nimmt sonst
    /// das nächste Gerät.
    ///
    /// Der Grund für diese Prüfung: „angeschlossen" heißt nicht „liefert Ton".
    /// Gemessen liefern das eingebaute Mikrofon bei geschlossenem Deckel und
    /// die AirPods Max digitale Stille, ohne sich irgendwie auffällig zu
    /// verhalten. Vorher nahm Sprachacus dann minutenlang nichts auf.
    private func scheduleSignalProbe() {
        signalProbe?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.checkForSignal() }
        signalProbe = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.probeDelay, execute: item)
    }

    private func checkForSignal() {
        guard engine != nil, onBuffer != nil, !sawSignal, let current = activeDeviceID else { return }
        silentDeviceIDs.insert(current)
        let silent = AudioDevices.name(forID: current) ?? "Mikrofon"
        guard let next = desiredDeviceID(), next != current else {
            onEvent?("„\(silent)“ liefert keinen Ton — es gibt kein anderes Mikrofon zum Ausweichen")
            return
        }
        onEvent?("„\(silent)“ liefert keinen Ton — wechsle auf „\(AudioDevices.name(forID: next) ?? "?")“")
        teardownEngine()
        do {
            try startEngine()
            scheduleSignalProbe()
        } catch {
            onEvent?("Ausweichen fehlgeschlagen: \(error.localizedDescription)")
            onRestartFailed?(error)
        }
    }

    /// Verschiebt die Prüfung aus dem Core-Audio-Rückruf heraus.
    ///
    /// Zwingend: Core Audio ruft seine Beobachter auf, während es intern noch
    /// Sperren hält. Wird aus dem Rückruf heraus eine AVAudioEngine angelegt,
    /// blockiert der Hauptthread für immer — gemessen, mit genau diesem
    /// Aufrufpfad. Die kurze Verzögerung bündelt außerdem die Schwärme von
    /// Meldungen, die ein Gerätewechsel auslöst, zu einer einzigen Prüfung.
    private func scheduleDeviceCheck() {
        pendingDeviceCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.followDeviceChange() }
        pendingDeviceCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// Reagiert auf einen Gerätewechsel im System — aber nur, wenn die Engine
    /// dadurch wirklich am falschen Gerät hängt. Sonst würde jedes Ein- und
    /// Ausstecken irgendeines Geräts die Aufnahme unterbrechen.
    private func followDeviceChange() {
        guard engine != nil, onBuffer != nil else { return }
        // Hat sich an der Geräteliste etwas geändert, bekommen auch vorher
        // stumme Geräte eine neue Chance — ein wieder verbundener Kopfhörer
        // funktioniert beim zweiten Versuch oft.
        let connected = Set(AudioDevices.inputs().map(\.id))
        if silentDeviceIDs.contains(where: { !connected.contains($0) }) {
            silentDeviceIDs = silentDeviceIDs.filter { connected.contains($0) }
        }
        guard let desired = desiredDeviceID(), desired != activeDeviceID else { return }
        let from = currentDeviceName ?? "unbekannt"
        let to = AudioDevices.name(forID: desired) ?? "unbekannt"
        onEvent?("Eingabegerät gewechselt: \(from) → \(to) — Aufnahme wird umgestellt")
        teardownEngine()
        do {
            try startEngine()
            scheduleSignalProbe()
        } catch {
            onEvent?("Umstellen auf \(to) fehlgeschlagen: \(error.localizedDescription)")
            onRestartFailed?(error)
        }
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, on input: AVAudioInputNode) {
        guard let unit = input.audioUnit else { return }
        var id = deviceID
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            onEvent?("Eingabegerät konnte nicht gesetzt werden (Status \(status)) — es gilt der Systemstandard")
        }
    }

    private func teardownEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        activeDeviceID = nil
        // Die letzte Freigabe absichtlich nicht auf dem Hauptthread:
        // `AVAudioEngine.dealloc` wartet per dispatch_sync auf die eigene
        // Warteschlange. Ist die gerade beschäftigt, steht sonst die ganze
        // Bedienoberfläche. Zweiter Gurt zum Hosenträger oben.
        DispatchQueue.global(qos: .utility).async {
            withExtendedLifetime(engine) {}
        }
    }

    /// Bündelt die Meldungen: Ein Gerätewechsel löst gleich mehrere aus.
    private func scheduleConfigurationRestart() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingConfigurationRestart?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.restartAfterConfigurationChange() }
            self.pendingConfigurationRestart = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
        }
    }

    /// A fresh engine is more reliable than re-installing a tap on the old one
    /// after a configuration change.
    private func restartAfterConfigurationChange() {
        guard engine != nil, onBuffer != nil else { return }
        // Haben wir die Engine gerade selbst (neu) gestartet, ist diese
        // Meldung die Folge davon und kein Grund, noch einmal neu zu starten.
        guard DispatchTime.now() > ignoreConfigurationChangesUntil else { return }
        onEvent?("Audio-Konfiguration geändert — Engine wird neu gestartet")
        teardownEngine()
        do {
            try startEngine()
            scheduleSignalProbe()
        } catch {
            onEvent?("Neustart des Mikrofons fehlgeschlagen: \(error.localizedDescription)")
            onRestartFailed?(error)
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(data, 1, &value, vDSP_Length(buffer.frameLength))
        return value
    }
}
