import Foundation
import FoundationModels

/// Generates the finished text for the assist mode. Unlike the dictation
/// refiner there is no passthrough fallback — if every provider fails the
/// error is surfaced in the panel, because there is nothing to pass through.
///
/// Provider order is deliberately Claude CLI first: the assist context is
/// FOREIGN text (a pasted email), and the on-device model was measured to
/// follow instructions hidden inside it (prompt injection) in 3 of 3 runs,
/// while also producing noticeably weaker replies. Apple Intelligence stays
/// available as an offline fallback.
enum AssistComposer {
    struct Output {
        let text: String
        let providerName: String
    }

    /// Above this combined length the on-device model's context window gets
    /// tight — it is skipped entirely.
    private static let localModelCharLimit = 6000

    static func compose(context: String?, instruction: String, languageCode: String) async throws -> Output {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            throw ClaudeCLI.CLIError(message: "Keine Anweisung angegeben")
        }

        let systemPrompt = AssistPrompts.systemPrompt(languageCode: languageCode)
        let userMessage = AssistPrompts.userMessage(context: context,
                                                    instruction: trimmedInstruction,
                                                    languageCode: languageCode)
        let fitsLocalModel = (context?.count ?? 0) + trimmedInstruction.count < localModelCharLimit

        var providers: [(name: String, run: () async throws -> String)] = []
        let claude = (name: "Claude CLI", run: {
            try await ClaudeCLI.run(systemPrompt: systemPrompt, input: userMessage,
                                    maxBudgetUSD: "0.10", timeout: 60)
        })
        let apple = (name: "Apple Intelligence", run: {
            let session = LanguageModelSession(instructions: systemPrompt)
            let response = try await session.respond(to: userMessage,
                                                     options: GenerationOptions(temperature: 0.4))
            return response.content
        })

        switch Settings.shared.assistProvider {
        case .auto:
            providers = [claude]
            if fitsLocalModel { providers.append(apple) }
        case .claudeCLI:
            providers = [claude]
        case .appleIntelligence:
            providers = fitsLocalModel ? [apple] : [claude]
        }

        var errors: [String] = []
        for provider in providers {
            if provider.name == "Apple Intelligence",
               case .unavailable = SystemLanguageModel.default.availability {
                errors.append("Apple Intelligence nicht aktiviert")
                continue
            }
            do {
                let cleaned = AssistPrompts.cleanOutput(try await provider.run())
                if !cleaned.isEmpty {
                    return Output(text: cleaned, providerName: provider.name)
                }
                errors.append("\(provider.name): leere Antwort")
            } catch {
                NSLog("AssistComposer: \(provider.name) failed: \(error.localizedDescription)")
                errors.append("\(provider.name): \(error.localizedDescription)")
            }
        }

        throw ClaudeCLI.CLIError(
            message: errors.isEmpty
                ? "Keine KI verfügbar. Installiere die Claude CLI oder aktiviere Apple Intelligence."
                : errors.joined(separator: " · ")
        )
    }
}
