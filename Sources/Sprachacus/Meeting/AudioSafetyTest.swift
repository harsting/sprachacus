import AVFoundation
import Foundation

/// Prüft, dass das Starten einer Meeting-Aufzeichnung die Tonwiedergabe des
/// Systems nicht beeinträchtigt — weder das Ausgabegerät umschaltet noch den
/// Pegel absenkt. Regressionstest zu einem Fehler, bei dem Apples Voice
/// Processing genau das tat und die Gegenseite unhörbar machte.
///
///   defaults write com.marvinharst.sprachacus runAudioSafetyTest -bool YES
@MainActor
enum AudioSafetyTest {
    static var logURL: URL { AppPaths.supportDir.appendingPathComponent("audiosafety.log") }

    private static func log(_ message: String) {
        NSLog("AUDIOSAFETY: \(message)")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    static func run() async {
        defer { UserDefaults.standard.set(false, forKey: "runAudioSafetyTest") }
        let deviceBefore = AudioDevices.defaultOutputName() ?? "?"
        log("Start — Ausgabegerät: \(deviceBefore)")

        let capture = SystemAudioCapture()
        nonisolated(unsafe) var peak: Float = 0
        capture.onLevel = { peak = max(peak, $0) }
        do { try await capture.start() } catch {
            log("FEHLER System-Audio: \(error.localizedDescription)"); return
        }

        peak = 0
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        let baseline = peak
        log(String(format: "Phase 1 (nur Mithören): Spitzenpegel %.5f", baseline))

        // Phase 2: Mikrofonaufnahme wie im Meeting dazuschalten
        var deviceDuring = deviceBefore
        let recorder = AudioRecorder()
        do {
            try recorder.start(deviceUID: Settings.shared.inputDeviceUID,
                               onBuffer: { _ in }, onLevel: { _ in })
            deviceDuring = AudioDevices.defaultOutputName() ?? "?"
            log("Mikrofonaufnahme läuft — Ausgabegerät jetzt: \(deviceDuring)")
        } catch {
            log("FEHLER Mikrofon: \(error.localizedDescription)")
        }
        peak = 0
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        let during = peak
        log(String(format: "Phase 2 (mit Mikrofonaufnahme): Spitzenpegel %.5f", during))

        recorder.stop()
        capture.stop()

        // Entscheidend ist der Zustand WÄHREND der Aufnahme. Ein Wechsel danach
        // ist normal: Kopfhörer trennen sich, sobald keine Audioaktivität mehr
        // läuft — das hat nichts mit Sprachacus zu tun.
        log("Ausgabegerät nach dem Stoppen: \(AudioDevices.defaultOutputName() ?? "?") (nur zur Information)")
        let deviceKept = deviceBefore == deviceDuring
        let levelKept = baseline <= 0 || during / baseline > 0.5
        log(deviceKept ? "✓ Ausgabegerät unverändert" : "✗ AUSGABEGERÄT WURDE GEWECHSELT")
        log(levelKept ? "✓ Wiedergabepegel unverändert" : "✗ WIEDERGABE WURDE ABGESENKT")
        log(deviceKept && levelKept ? "ERGEBNIS: unbedenklich" : "ERGEBNIS: BEEINTRÄCHTIGT DIE WIEDERGABE")
    }
}
