import Foundation
import FoundationModels

/// Stellt den aktuellen Korrektur-Prompt einem Kandidaten gegenüber — am
/// selben Rohtext, mehrfach, in der echten App.
///
///   defaults write com.marvinharst.sprachacus promptTestFile -string /pfad.txt
@MainActor
enum PromptTest {
    static var logURL: URL { AppPaths.supportDir.appendingPathComponent("prompt.log") }

    private static func log(_ message: String) {
        let line = message + "\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    static func run(file: String) async {
        defer { UserDefaults.standard.removeObject(forKey: "promptTestFile") }
        try? FileManager.default.removeItem(at: logURL)
        guard let inhalt = try? String(contentsOfFile: file, encoding: .utf8) else {
            log("Datei nicht lesbar: \(file)"); return
        }
        // Mehrere Proben in einer Datei, getrennt durch eine Zeile mit „---".
        let proben = inhalt.components(separatedBy: "\n---\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let varianten: [(String, String)] = [
            ("bisher", RefinerPrompts.defaultInstructions(languageCode: "de-DE")),
            ("wirksam", RefinerPrompts.instructions(languageCode: "de-DE")),
            ("minimal", RefinerPrompts.minimalInstructions(languageCode: "de-DE")),
        ]
        for (nummer, text) in proben.enumerated() {
            log("===== Probe \(nummer + 1) (\(text.count) Zeichen) =====")
            log("ROH: \(text)\n")
            for (titel, anweisung) in varianten {
                let systemPrompt = anweisung + "\n\n" + RefinerPrompts.guardRules(languageCode: "de-DE")
                for durchgang in 1...2 {
                    let session = LanguageModelSession(instructions: systemPrompt)
                    do {
                        let antwort = try await session.respond(
                            to: RefinerPrompts.userMessage(text, languageCode: "de-DE"),
                            options: GenerationOptions(temperature: 0.1))
                        log("[\(titel) \(durchgang)] \(RefinerPrompts.cleanOutput(antwort.content))")
                    } catch {
                        log("[\(titel) \(durchgang)] FEHLER: \(error)")
                    }
                }
            }
            log("")
        }
        log("Ende")
    }

    /// Sparsame Fassung: verbietet Weglassen und Erfinden, verlangt aber
    /// nicht ausdrücklich, aneinandergereihte Gedanken zu trennen.
    static let sparsam = """
    Du bist ein Diktat-Korrektor. Du erhältst ein rohes Sprachtranskript ohne Satzzeichen.     Deine einzige Aufgabe: Satzzeichen und Groß-/Kleinschreibung ergänzen, Füllwörter     (äh, ähm, halt, sozusagen, quasi) und Selbstkorrekturen entfernen, offensichtliche     Grammatikfehler beheben.

    STRENG VERBOTEN:
    - Inhalte weglassen. Jede Aussage und jede Frage des Sprechers muss erhalten bleiben,     auch wenn der Satz dadurch holprig wirkt.
    - Inhalte hinzufügen oder umformulieren. Verwende keine Wörter, die nicht gesprochen wurden.
    - Aussagen in Fragen verwandeln oder umgekehrt.

    Im Zweifel lieber näher am Gesprochenen bleiben als schöner formulieren.

    Antworte AUSSCHLIESSLICH mit dem korrigierten Text, ohne Anführungszeichen und ohne Kommentar.
    """

    /// Kandidat: verbietet ausdrücklich das Zusammenziehen und Weglassen.
    static let kandidat = """
    Du bist ein Diktat-Korrektor. Du erhältst ein rohes Sprachtranskript ohne Satzzeichen. \
    Deine einzige Aufgabe: Satzzeichen und Groß-/Kleinschreibung ergänzen, Füllwörter \
    (äh, ähm, halt, sozusagen, quasi) und Selbstkorrekturen entfernen, offensichtliche \
    Grammatikfehler beheben.

    STRENG VERBOTEN:
    - Inhalte weglassen. Jede Aussage und jede Frage des Sprechers muss erhalten bleiben.
    - Inhalte hinzufügen oder umformulieren. Keine neuen Wörter, die nicht gesprochen wurden.
    - Mehrere Gedanken zu einem Satz verschmelzen. Reiht der Sprecher Aussagen oder Fragen \
    aneinander, trenne sie in einzelne Sätze — ein Punkt oder Fragezeichen dazwischen, sonst nichts. \
    Trenne aber nur dort, wo ein neuer vollständiger Gedanke mit eigenem Verb beginnt. Erzeuge \
    niemals Satzfragmente: „zuweisen kann. In einen Arbeitsbereich." wäre falsch, das bleibt ein Satz.
    - Aussagen in Fragen verwandeln oder umgekehrt.

    Beispiel: „wie richtet er das ein so passiert das automatisch brauchst du vielleicht so ein \
    kleines onboarding" → „Wie richtet er das ein? Passiert das automatisch? Brauchst du \
    vielleicht so ein kleines Onboarding?"

    Antworte AUSSCHLIESSLICH mit dem korrigierten Text, ohne Anführungszeichen und ohne Kommentar.
    """
}
