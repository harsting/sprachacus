import Foundation
import FoundationModels

/// Refines the transcript with Apple's on-device foundation model
/// (Apple Intelligence). Free, local, fast — the default refiner.
final class FoundationModelsRefiner: TextRefiner {
    let name = "Apple Intelligence"

    /// Vorgewärmte Sitzung für das nächste Diktat.
    ///
    /// Kalt kostet das Modell ein Vielfaches: gemessen 15,0 s beim ersten
    /// Aufruf, danach 0,9 s, mit vorgewärmter Sitzung 0,66 s. Deshalb wird
    /// beim Start der Aufnahme schon angewärmt — die Zeit vergeht dann
    /// während des Sprechens statt danach.
    private static let warmLock = NSLock()
    private static var warmSession: LanguageModelSession?
    /// Die Anweisungen, mit denen die vorgewärmte Sitzung gebaut wurde.
    /// Ändert der Nutzer Sprache, Prompt oder eigene Begriffe, taugt sie nicht
    /// mehr.
    private static var warmInstructions: String?

    static func prewarm(languageCode: String) {
        guard case .available = SystemLanguageModel.default.availability else { return }
        let instructions = RefinerPrompts.systemPrompt(languageCode: languageCode)
        warmLock.lock()
        let alreadyWarm = warmSession != nil && warmInstructions == instructions
        warmLock.unlock()
        guard !alreadyWarm else { return }

        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        warmLock.lock()
        warmSession = session
        warmInstructions = instructions
        warmLock.unlock()
    }

    /// Nimmt die vorgewärmte Sitzung heraus — jedes Diktat bekommt eine
    /// eigene, damit sich nichts aus dem vorherigen vermischt.
    private static func takeWarmSession(instructions: String) -> LanguageModelSession? {
        warmLock.lock()
        defer { warmLock.unlock() }
        guard warmInstructions == instructions, let session = warmSession else { return nil }
        warmSession = nil
        warmInstructions = nil
        return session
    }

    func isAvailable() async -> Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func refine(_ raw: String, languageCode: String) async throws -> String {
        // The on-device model has a small context window (~4k tokens);
        // for very long dictations skip refinement rather than truncating.
        guard raw.count < 8000 else {
            throw RefinerError(message: "Transkript zu lang für das lokale Modell")
        }
        let instructions = RefinerPrompts.systemPrompt(languageCode: languageCode)
        let session = Self.takeWarmSession(instructions: instructions)
            ?? LanguageModelSession(instructions: instructions)
        defer {
            // Gleich für das nächste Diktat wieder anwärmen.
            Task.detached { Self.prewarm(languageCode: languageCode) }
        }
        let message = RefinerPrompts.userMessage(raw, languageCode: languageCode)
        let options = GenerationOptions(temperature: 0.1)
        do {
            return try await session.respond(to: message, options: options).content
        } catch {
            // Apples Modell verweigert gelegentlich die Antwort
            // („Response may contain sensitive or unsafe content") — gemessen
            // an einem völlig harmlosen Satz über Schichtplanung, und beim
            // zweiten Versuch war es weg. Ohne Wiederholung landet dann der
            // unkorrigierte Rohtext im Dokument.
            NSLog("Apple Intelligence: erster Versuch fehlgeschlagen (\(error)) — einmal wiederholen")
            let retry = LanguageModelSession(instructions: instructions)
            return try await retry.respond(to: message, options: options).content
        }
    }
}
