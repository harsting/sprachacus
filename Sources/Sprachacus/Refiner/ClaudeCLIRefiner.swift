import Foundation

/// Refines the transcript by shelling out to the Claude Code CLI in
/// non-interactive print mode with the Haiku model. With a Claude
/// subscription this is effectively free.
final class ClaudeCLIRefiner: TextRefiner {
    let name = "Claude CLI"

    func isAvailable() async -> Bool { ClaudeCLI.isAvailable }

    static func resolveClaudePath() -> String? { ClaudeCLI.resolvePath() }

    func refine(_ raw: String, languageCode: String) async throws -> String {
        try await ClaudeCLI.run(
            systemPrompt: RefinerPrompts.systemPrompt(languageCode: languageCode),
            input: RefinerPrompts.userMessage(raw, languageCode: languageCode),
            maxBudgetUSD: "0.05",
            timeout: 30
        )
    }
}
