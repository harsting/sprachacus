import AVFoundation
import Foundation

/// Prüft, dass die Aufnahme einem Wechsel des Eingabegeräts folgt.
///
/// Regressionstest zu einem Fehler vom 05.10.: Beim Beitreten zu einem Meeting
/// wurde auf ein Tischmikrofon gewechselt, die Engine las aber weiter vom alten
/// Gerät. Neun Minuten Gespräch ohne einen einzigen eigenen Abschnitt — und
/// ohne jeden Hinweis darauf.
///
/// Der Test schreibt jede Sekunde das aktive Gerät, den Spitzenpegel und den
/// Anteil von Null-Abtastwerten mit. Letzteres unterscheidet ein leises
/// Mikrofon von einem toten: Ein lebendiges Gerät rauscht immer ein wenig,
/// ein totes liefert exakte Nullen.
///
/// Währenddessen das Eingabegerät umstellen: Im Protokoll muss der Wechsel
/// auftauchen und der Pegel danach weiterlaufen.
///
///   defaults write com.marvinharst.sprachacus runMicDeviceTest -bool YES
///   defaults write com.marvinharst.sprachacus micDeviceTestUID -string "<UID>"   # optional: festes Gerät
///   defaults write com.marvinharst.sprachacus micDeviceTestSeconds -int 30        # optional
@MainActor
enum MicDeviceTest {
    static var logURL: URL { AppPaths.supportDir.appendingPathComponent("mic-device-test.log") }

    private static func log(_ message: String) {
        NSLog("MICTEST: \(message)")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    static func run() async {
        defer {
            UserDefaults.standard.set(false, forKey: "runMicDeviceTest")
            UserDefaults.standard.removeObject(forKey: "micDeviceTestUID")
        }
        try? FileManager.default.removeItem(at: logURL)
        let pinned = UserDefaults.standard.string(forKey: "micDeviceTestUID").flatMap { $0.isEmpty ? nil : $0 }
        let seconds = max(5, UserDefaults.standard.object(forKey: "micDeviceTestSeconds") as? Int ?? 30)
        let systemDefault = AudioDevices.defaultInputID().flatMap { AudioDevices.name(forID: $0) } ?? "?"
        log("Start — Standardeingang laut System: \(systemDefault)")
        log("Festes Gerät: \(pinned.flatMap { AudioDevices.name(forUID: $0) } ?? "keines (Systemstandard)")")

        let recorder = AudioRecorder()
        recorder.onEvent = { log("EREIGNIS: \($0)") }
        recorder.onRestartFailed = { log("FEHLER: Neustart fehlgeschlagen — \($0.localizedDescription)") }
        nonisolated(unsafe) var peak: Float = 0
        nonisolated(unsafe) var frames = 0
        nonisolated(unsafe) var nonzero = 0
        do {
            try recorder.start(
                deviceUID: pinned,
                onBuffer: { buffer in
                    guard let data = buffer.floatChannelData?[0] else { return }
                    for index in 0..<Int(buffer.frameLength) where data[index] != 0 { nonzero += 1 }
                    frames += Int(buffer.frameLength)
                },
                onLevel: { peak = max(peak, $0) })
        } catch {
            log("FEHLER beim Start: \(error.localizedDescription)")
            return
        }

        for second in 1...seconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let share = frames > 0 ? Double(nonzero) / Double(frames) * 100 : 0
            log(String(format: "%2d s  Gerät: %-24@  Spitzenpegel: %.8f  Abtastwerte: %6d  davon ≠ 0: %5.1f %%",
                       second, recorder.currentDeviceName ?? "—", peak, frames, share))
            peak = 0
            frames = 0
            nonzero = 0
        }
        recorder.stop()
        log("Ende")
    }
}
