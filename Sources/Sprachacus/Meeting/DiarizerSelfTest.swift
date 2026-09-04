import FluidAudio
import Foundation

/// Prüft die Sprechertrennung an einer vorhandenen Aufnahme, ohne ein echtes
/// Meeting aufzeichnen zu müssen:
///
///   defaults write com.marvinharst.sprachacus diarizerTestFile -string /pfad/mix.wav
///   open -a Sprachacus
///   cat ~/Library/Application\ Support/Sprachacus/diarizer.log
@MainActor
enum DiarizerSelfTest {
    static var logURL: URL { AppPaths.supportDir.appendingPathComponent("diarizer.log") }

    private static func log(_ message: String) {
        NSLog("DIARIZER: \(message)")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    static func run(path: String) async {
        defer { UserDefaults.standard.removeObject(forKey: "diarizerTestFile") }
        log("Start mit \(path)")
        log("Modelle bereits vorhanden: \(SpeakerDiarizer.modelsReady)")

        // Ein Abschnitt pro Sekunde — so lässt sich ablesen, welcher Sprecher
        // die Diarisierung zu welchem Zeitpunkt zugeordnet hat.
        let probes = stride(from: 0.0, to: 18.0, by: 1.0).map {
            MeetingSegment(source: .others, text: "Sekunde \(Int($0))", t: $0, end: $0 + 1)
        }
        // Standardeinstellung
        if let raw = try? await rawSegments(path: path, forcedSpeakers: nil) {
            log("STANDARD: \(raw.count) Abschnitte, \(Set(raw.map { $0.0 }).count) Sprecher")
            for (id, start, end) in raw.prefix(25) { log(String(format: "   %@  %.1f–%.1f s", id, start, end)) }
        }
        // Erzwungene Sprecherzahl — zeigt, ob die Einbettungen überhaupt
        // unterscheidbar sind oder nur die Gruppierung zu grob ist.
        if let raw = try? await rawSegments(path: path, forcedSpeakers: 3) {
            log("ERZWUNGEN 3: \(raw.count) Abschnitte, \(Set(raw.map { $0.0 }).count) Sprecher")
            for (id, start, end) in raw.prefix(25) { log(String(format: "   %@  %.1f–%.1f s", id, start, end)) }
        }
        let started = Date()
        do {
            let result = try await SpeakerDiarizer.assignSpeakers(
                to: probes,
                audioURL: URL(fileURLWithPath: path),
                onProgress: { text in Task { @MainActor in log("Fortschritt: \(text)") } })
            log("Dauer: \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            for segment in result {
                log("  t=\(Int(segment.t))s → \(segment.speaker ?? "(kein Sprecher)")")
            }
        } catch {
            log("FEHLER: \(error.localizedDescription)")
        }
        log("fertig")
    }

    private static func rawSegments(path: String, forcedSpeakers: Int?) async throws -> [(String, Float, Float)] {
        var config = OfflineDiarizerConfig.default
        if let forcedSpeakers { config.clustering.numSpeakers = forcedSpeakers }
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        let result = try await manager.process(URL(fileURLWithPath: path))
        return result.segments.map { ($0.speakerId, $0.startTimeSeconds, $0.endTimeSeconds) }
    }
}
