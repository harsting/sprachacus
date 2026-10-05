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
    private var deviceUID: String?
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

    /// - Parameter deviceUID: fixed input device; nil follows the system default.
    ///
    /// Bewusst OHNE Apples Voice Processing: Es schaltet das systemweite
    /// Ausgabegerät um (gemessen: von AirPods auf die internen Lautsprecher)
    /// und senkt den Ton anderer Apps auf null — mitten im Meeting hört man
    /// die Gegenseite dann nicht mehr. Das Echo wird stattdessen auf
    /// Transkriptebene herausgefiltert (siehe MeetingController).
    func start(deviceUID: String? = nil,
               onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
               onLevel: @escaping (Float) -> Void) throws {
        stop()
        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.deviceUID = deviceUID
        try startEngine()

        // Route changes (headphones in/out, sample-rate switch) invalidate the
        // tap format. React outside the notification handler — tearing the
        // engine down inside it is not allowed.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.restartAfterConfigurationChange() }
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
        teardownEngine()
        onBuffer = nil
        onLevel = nil
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Must happen before the format is read and before the engine starts.
        if let deviceUID {
            if let deviceID = AudioDevices.deviceID(forUID: deviceUID) {
                setInputDevice(deviceID, on: input)
            } else {
                onEvent?("Gewähltes Mikrofon ist nicht angeschlossen — es gilt der Systemstandard")
            }
        }

        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.onLevel?(Self.rms(buffer))
            self.onBuffer?(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        activeDeviceID = desiredDeviceID()
        lastDeviceWasBuiltIn = isUsingBuiltInMicrophone
        onEvent?("Mikrofon aktiv: \(currentDeviceName ?? "unbekannt") — \(Int(format.sampleRate)) Hz, \(format.channelCount) Kanal(e)")
    }

    /// Welches Gerät die Engine benutzen *soll*: das fest gewählte, sonst das
    /// aktuelle Standardgerät des Systems.
    private func desiredDeviceID() -> AudioDeviceID? {
        if let deviceUID, let id = AudioDevices.deviceID(forUID: deviceUID) { return id }
        return AudioDevices.defaultInputID()
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
        guard let desired = desiredDeviceID(), desired != activeDeviceID else { return }
        let from = currentDeviceName ?? "unbekannt"
        let to = AudioDevices.name(forID: desired) ?? "unbekannt"
        onEvent?("Eingabegerät gewechselt: \(from) → \(to) — Aufnahme wird umgestellt")
        teardownEngine()
        do {
            try startEngine()
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
    }

    /// A fresh engine is more reliable than re-installing a tap on the old one
    /// after a configuration change.
    private func restartAfterConfigurationChange() {
        guard engine != nil, onBuffer != nil else { return }
        onEvent?("Audio-Konfiguration geändert — Engine wird neu gestartet")
        teardownEngine()
        do {
            try startEngine()
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
