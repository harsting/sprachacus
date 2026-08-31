import Foundation
import FoundationModels

/// Refines the transcript with Apple's on-device foundation model
/// (Apple Intelligence). Free, local, fast — the default refiner.
final class FoundationModelsRefiner: TextRefiner {
    let name = "Apple Intelligence"

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
        let session = LanguageModelSession(instructions: RefinerPrompts.systemPrompt(languageCode: languageCode))
        let response = try await session.respond(
            to: RefinerPrompts.userMessage(raw, languageCode: languageCode),
            options: GenerationOptions(temperature: 0.1)
        )
        return response.content
    }
}
