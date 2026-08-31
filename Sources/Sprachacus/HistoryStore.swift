import Foundation
import SwiftUI

enum HistoryKind: String, Codable {
    case dictation
    case assist

    var title: String {
        switch self {
        case .dictation: return "Diktat"
        case .assist: return "Assist"
        }
    }
}

struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    var raw: String
    var refined: String
    var refinerName: String
    var languageCode: String
    var kind: HistoryKind

    init(id: UUID = UUID(), date: Date = Date(), raw: String, refined: String,
         refinerName: String, languageCode: String, kind: HistoryKind = .dictation) {
        self.id = id
        self.date = date
        self.raw = raw
        self.refined = refined
        self.refinerName = refinerName
        self.languageCode = languageCode
        self.kind = kind
    }

    /// Entries written before the assist feature have no `kind` — treat them as dictations.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        raw = try container.decode(String.self, forKey: .raw)
        refined = try container.decode(String.self, forKey: .refined)
        refinerName = try container.decode(String.self, forKey: .refinerName)
        languageCode = try container.decode(String.self, forKey: .languageCode)
        kind = try container.decodeIfPresent(HistoryKind.self, forKey: .kind) ?? .dictation
    }
}

/// Keeps the last dictations and assist results (raw + refined + which provider
/// ran) and persists them as JSON in Application Support.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []
    private let maxEntries = 100

    private var fileURL: URL {
        AppPaths.supportDir.appendingPathComponent("history.json")
    }

    private init() {
        load()
    }

    func add(raw: String, refined: String, refinerName: String,
             languageCode: String, kind: HistoryKind = .dictation) {
        entries.insert(
            HistoryEntry(raw: raw, refined: refined, refinerName: refinerName,
                         languageCode: languageCode, kind: kind),
            at: 0
        )
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save()
    }

    func update(_ entry: HistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
