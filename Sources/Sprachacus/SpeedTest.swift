import AVFoundation
import Foundation
import FoundationModels

/// Misst, wo beim Diktat die Zeit hingeht — in der echten App, weil Apple
/// Intelligence außerhalb einer App ganz andere (viel schlechtere) Zeiten
/// liefert.
///
///   defaults write com.marvinharst.sprachacus speedTestFile -string /pfad.wav
@MainActor
enum SpeedTest {
    static var logURL: URL { AppPaths.supportDir.appendingPathComponent("tempo.log") }

    private static func log(_ message: String) {
        NSLog("TEMPO: \(message)")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    private static func ms(_ start: Date) -> String {
        String(format: "%7.0f ms", Date().timeIntervalSince(start) * 1000)
    }

    static func run(file: String) async {
        defer { UserDefaults.standard.removeObject(forKey: "speedTestFile") }
        try? FileManager.default.removeItem(at: logURL)
        let locale = Locale(identifier: Settings.shared.localeIdentifier)
        log("Start — Sprache \(locale.identifier), Korrektur: \(Settings.shared.refiner.title)")

        // 1. Was beim Tastendruck passiert, bevor überhaupt aufgenommen wird.
        let openStart = Date()
        let transcriber = Transcriber()
        var raw = ""
        do {
            try await transcriber.start(locale: locale,
                                        vocabulary: Settings.shared.vocabularyTerms,
                                        onPartial: { _ in })
        } catch {
            log("Erkennung ließ sich nicht öffnen: \(error.localizedDescription)")
            return
        }
        log("1. Erkennung öffnen (vor der ersten Aufnahme):  \(ms(openStart))")

        // 2. Ton in Echtzeit einspeisen wie beim Sprechen.
        guard let audio = try? AVAudioFile(forReading: URL(fileURLWithPath: file)) else {
            log("Datei nicht lesbar: \(file)"); return
        }
        let format = audio.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate * 0.2)
        while audio.framePosition < audio.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try? audio.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            transcriber.feed(buffer)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // 3. Die spürbare Wartezeit: vom Loslassen bis zum fertigen Text.
        let stopStart = Date()
        raw = (try? await transcriber.finish(timeout: 12)) ?? ""
        log("2. Abschluss nach dem Stoppen:                  \(ms(stopStart))   (\(raw.count) Zeichen)")

        // 4. Korrektur für verschiedene Längen, jeweils mit vorgewärmter
        //    Sitzung — so, wie es nach dem Umbau im Alltag läuft.
        let mittel = String(repeating: "Wir sollten das Angebot nochmal durchgehen bevor es rausgeht. ", count: 6)
        let lang = String(repeating: "Ich habe heute mit dem Kunden gesprochen und wir sind so verblieben dass wir die Unterlagen bis Freitag schicken. ", count: 11)
        for (titel, text) in [("kurz  \(raw.count) Zeichen", raw),
                              ("mittel \(mittel.count) Zeichen", mittel),
                              ("lang  \(lang.count) Zeichen", lang)] {
            FoundationModelsRefiner.prewarm(languageCode: locale.identifier)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let start = Date()
            let (out, name) = await RefinerChain.current().refine(text, languageCode: locale.identifier)
            log("3. Korrektur \(titel) über \(name):   \(ms(start))   (→ \(out.count) Zeichen)")
        }

        // 5. Dieselbe Korrektur mit vorgewärmter Sitzung.
        if case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(
                instructions: RefinerPrompts.systemPrompt(languageCode: locale.identifier))
            let warmStart = Date()
            session.prewarm()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            log("4. prewarm() + 1,2 s Wartezeit:                 \(ms(warmStart))")
            let start = Date()
            do {
                let answer = try await session.respond(
                    to: RefinerPrompts.userMessage(raw, languageCode: locale.identifier),
                    options: GenerationOptions(temperature: 0.1))
                log("5. Antwort der vorgewärmten Sitzung:            \(ms(start))   (\(answer.content.count) Zeichen)")
            } catch {
                log("5. Vorgewärmte Sitzung scheiterte: \(error)")
            }
        }
        log("Ende")
    }
}
