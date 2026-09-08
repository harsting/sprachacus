import AVFoundation
import Accelerate
import CoreAudio

/// Captures microphone audio via AVAudioEngine. One input tap feeds both the
/// transcriber (raw buffers) and the overlay waveform (RMS level).
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onLevel: ((Float) -> Void)?
    private var deviceUID: String?

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
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        teardownEngine()
        onBuffer = nil
        onLevel = nil
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Must happen before the format is read and before the engine starts.
        if let deviceUID, let deviceID = AudioDevices.deviceID(forUID: deviceUID) {
            setInputDevice(deviceID, on: input)
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
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, on input: AVAudioInputNode) {
        guard let unit = input.audioUnit else { return }
        var id = deviceID
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            NSLog("AudioRecorder: Eingabegerät konnte nicht gesetzt werden (Status \(status)) — nutze Systemstandard")
        }
    }

    private func teardownEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// A fresh engine is more reliable than re-installing a tap on the old one
    /// after a configuration change.
    private func restartAfterConfigurationChange() {
        guard engine != nil, onBuffer != nil else { return }
        NSLog("AudioRecorder: Audio-Konfiguration geändert — Engine wird neu gestartet")
        teardownEngine()
        do {
            try startEngine()
        } catch {
            NSLog("AudioRecorder: Neustart fehlgeschlagen: \(error.localizedDescription)")
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
