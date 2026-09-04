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
    private var echoCancellation = false

    /// Reports a failed recovery after an audio route change (e.g. AirPods
    /// connected mid-recording). The mic is dead at that point.
    var onRestartFailed: ((Error) -> Void)?

    var isRunning: Bool { engine != nil }

    /// - Parameters:
    ///   - deviceUID: fixed input device; nil follows the system default.
    ///   - echoCancellation: enables Apple's voice processing so the far side
    ///     of a call played over speakers does not bleed into the microphone.
    ///     Only used for meetings — it also applies noise suppression and gain
    ///     control, which is unwanted for plain dictation.
    func start(deviceUID: String? = nil,
               echoCancellation: Bool = false,
               onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
               onLevel: @escaping (Float) -> Void) throws {
        stop()
        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.deviceUID = deviceUID
        self.echoCancellation = echoCancellation
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

        // Voice processing changes the node's channel layout (the processed
        // signal stays on channel 0, reference channels follow), so from here
        // on only channel 0 may be used.
        var usesVoiceProcessing = false
        if echoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
                usesVoiceProcessing = input.isVoiceProcessingEnabled
            } catch {
                NSLog("AudioRecorder: Echo-Unterdrückung nicht verfügbar: \(error.localizedDescription)")
            }
        }

        let format = input.outputFormat(forBus: 0)
        let monoFormat = usesVoiceProcessing
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                            channels: 1, interleaved: false)
            : nil

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let usable = monoFormat.flatMap { Self.firstChannel(of: buffer, as: $0) } ?? buffer
            self.onLevel?(Self.rms(usable))
            self.onBuffer?(usable)
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

    /// Kopiert nur Kanal 0 — bei aktiver Echo-Unterdrückung ist das das
    /// bereinigte Signal; ein Downmix würde die Referenzkanäle einmischen.
    private static func firstChannel(of buffer: AVAudioPCMBuffer,
                                     as format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData, buffer.frameLength > 0,
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength)
        else { return nil }
        mono.frameLength = buffer.frameLength
        memcpy(mono.floatChannelData![0], source[0],
               Int(buffer.frameLength) * MemoryLayout<Float>.size)
        return mono
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
