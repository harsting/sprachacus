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

        // 4. Korrektur für echte Textlängen. Bewusst NICHT wiederholter Text:
        //    Ein sich wiederholender Absatz wird vom Modell zusammengestrichen,
        //    die Zeiten sind dann wertlos.
        for text in Self.proben() {
            FoundationModelsRefiner.prewarm(languageCode: locale.identifier)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let start = Date()
            let (out, name) = await RefinerChain.current().refine(text, languageCode: locale.identifier)
            let dauer = Date().timeIntervalSince(start)
            let limit = RefinerChain.deadline(for: text)
            log(String(format: "3. %5d Zeichen → %5d über %@: %7.0f ms   (Zeitlimit %.1f s, %@, %.0f Zeichen/s)",
                       text.count, out.count, name, dauer * 1000, limit,
                       dauer < limit ? "eingehalten" : "GERISSEN", Double(out.count) / dauer))
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

    /// Echte Diktatlängen: ein zusammenhängender Text, der mit jedem Satz
    /// weitergeht, damit das Modell wirklich alles neu schreiben muss.
    private static func proben() -> [String] {
        let saetze = [
            "Ich hatte heute Vormittag ein längeres Gespräch mit dem Kunden über die Lieferung der neuen Geräte.",
            "Wir haben vereinbart dass die erste Charge bis Ende des Monats im Lager steht und vorher noch geprüft wird.",
            "Bitte klär mit der Buchhaltung ob die Rechnung vom letzten Quartal inzwischen ausgeglichen wurde.",
            "Außerdem braucht die Technik eine Rückmeldung zu den Anschlüssen im zweiten Obergeschoss.",
            "Der Kollege aus dem Vertrieb meldet sich morgen wegen der Konditionen für den Rahmenvertrag.",
            "Ich schlage vor dass wir uns Freitag kurz zusammensetzen und die offenen Punkte durchgehen.",
            "Wichtig wäre mir dass wir vorher die Zahlen aus dem September vorliegen haben.",
            "Die Unterlagen für die Prüfung liegen bei mir auf dem Schreibtisch und können abgeholt werden.",
            "Für die Schulung im November brauchen wir noch eine Rückmeldung wie viele Plätze gebraucht werden.",
            "Zum Schluss bitte ich dich den Termin mit dem Lieferanten auf nächste Woche zu verschieben.",
            "Der Prüfbericht vom Dienstag enthält zwei Punkte die wir noch nachbessern müssen.",
            "Ich habe das Angebot überarbeitet und die Preise an die neue Kalkulation angepasst.",
            "Die Kollegen aus der Produktion melden dass die Maschine seit Montag wieder störungsfrei läuft.",
            "Bitte denk daran die Zugänge für die neuen Mitarbeiter rechtzeitig zu beantragen.",
            "Ansonsten bleibt es bei der Planung wie wir sie im letzten Jour fixe besprochen haben.",
            "Melde dich gern wenn dazu noch etwas unklar ist dann gehen wir es gemeinsam durch.",
            "Die Anfrage aus Hamburg ist gestern Abend noch eingegangen und sollte heute beantwortet werden.",
            "Im Lager fehlen laut Inventur zwei Paletten die vermutlich falsch verbucht worden sind.",
            "Der neue Dienstleister stellt sich kommende Woche vor und bringt Referenzen mit.",
            "Für das Projekt im Süden brauchen wir bis Mittwoch eine verbindliche Zusage vom Partner.",
            "Die Dokumentation zur Anlage ist inzwischen vollständig und liegt im gemeinsamen Ordner.",
            "Ich habe die Mängelliste durchgesehen und drei Punkte als dringend markiert.",
            "Beim Wareneingang sollten wir künftig jede Lieferung fotografieren um Streit zu vermeiden.",
            "Der Mietvertrag für die Halle läuft im Frühjahr aus und muss rechtzeitig verlängert werden.",
            "Die Rückmeldungen aus der Umfrage sind erfreulich und zeigen vor allem Lob für den Service.",
            "Zum Jahresende brauchen wir eine Übersicht über alle offenen Posten der großen Kunden.",
            "Bitte lege den Entwurf für die Präsentation auf meinen Tisch ich schaue ihn morgen durch.",
            "Die Zusammenarbeit mit der Agentur läuft gut auch wenn die Abstimmung manchmal dauert.",
        ]
        var proben: [String] = []
        for ziel in [1000, 2000, 2600] {
            var text = ""
            var index = 0
            while text.count < ziel {
                text += saetze[index % saetze.count] + " "
                index += 1
            }
            proben.append(text.trimmingCharacters(in: .whitespaces))
        }
        return proben
    }
}
