import Foundation

final class PassthroughRefiner: TextRefiner {
    let name = "Rohtext"
    func isAvailable() async -> Bool { true }
    func refine(_ raw: String, languageCode: String) async throws -> String { raw }
}
