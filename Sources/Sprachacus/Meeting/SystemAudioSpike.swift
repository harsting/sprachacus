import AVFoundation
import Foundation

/// Diagnostic self-test for the meeting pipeline: runs microphone capture and
/// system-audio capture through two concurrent SpeechAnalyzer sessions and
/// logs what each channel understood.
///
/// Triggered out-of-band so it can run without UI:
///   defaults write com.marvinharst.sprachacus runSystemAudioSpike -bool YES
///   open -a Sprachacus
/// Results: `log show --predicate 'process == "Sprachacus"' | grep SPIKE`
@MainActor
enum SystemAudioSpike {
    /// NSLog from a GUI app is not reliably readable via `log show`, so the
    /// spike also appends to a file the developer can just `cat`.
    static var logURL: URL { AppPaths.supportDir.appendingPathComponent("spike.log") }

    private static func log(_ message: String) {
        NSLog("SPIKE: \(message)")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    static func run(duration: TimeInterval = 30) async {
        log("start (Dauer \(Int(duration)) s)")
        defer { UserDefaults.standard.set(false, forKey: "runSystemAudioSpike") }

        let locale = Locale(identifier: Settings.shared.localeIdentifier)
        guard await Transcriber.isModelInstalled(locale: locale) else {
            log("FEHLER Sprachmodell nicht installiert")
            return
        }

        log("Bildschirmaufnahme-Berechtigung vorab: \(SystemAudioCapture.hasPermission)")
        if !SystemAudioCapture.hasPermission {
            SystemAudioCapture.requestPermission()
            log("Berechtigung angefordert — Dialog bestätigen und Spike erneut starten")
            return
        }

        let micTranscriber = Transcriber()
        let sysTranscriber = Transcriber()
        let recorder = AudioRecorder()
        let capture = SystemAudioCapture()

        do {
            try await micTranscriber.start(locale: locale, onPartial: { _ in }, onFinalSegment: { text in
                log("[ICH] \(text)")
            })
            try await sysTranscriber.start(locale: locale, onPartial: { _ in }, onFinalSegment: { text in
                log("[ANDERE] \(text)")
            })

            try recorder.start(onBuffer: { [weak micTranscriber] buffer in
                micTranscriber?.feed(buffer)
            }, onLevel: { _ in })
            log("Mikrofon läuft")

            capture.onBuffer = { [weak sysTranscriber] buffer in
                sysTranscriber?.feed(buffer)
            }
            capture.onStopped = { error in
                log("System-Audio abgebrochen: \(error.localizedDescription)")
            }
            try await capture.start()
            log("System-Audio läuft — beide Analyzer parallel aktiv")
        } catch {
            log("FEHLER beim Start: \(error.localizedDescription)")
            recorder.stop()
            capture.stop()
            micTranscriber.cancel()
            sysTranscriber.cancel()
            return
        }

        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

        recorder.stop()
        capture.stop()
        let micText = (try? await micTranscriber.finish()) ?? ""
        let sysText = (try? await sysTranscriber.finish()) ?? ""
        log("ERGEBNIS Mikrofon: \(micText.isEmpty ? "(leer)" : micText)")
        log("ERGEBNIS System-Audio: \(sysText.isEmpty ? "(leer)" : sysText)")
        log("fertig")
    }
}
