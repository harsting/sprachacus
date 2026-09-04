import Foundation
import SwiftUI

struct MeetingSegment: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        case me = "ich"
        case others = "andere"

        var label: String {
            switch self {
            case .me: return "Ich"
            case .others: return "Andere"
            }
        }
    }

    var id = UUID()
    let source: Source
    let text: String
    /// Startzeit auf der Tonspur, in Sekunden seit Aufnahmebeginn.
    let t: TimeInterval
    /// Endzeit; bei Altbestand nicht vorhanden.
    var end: TimeInterval?
    /// Von der Sprechertrennung vergebene Kennung („Sprecher 1“), nur für
    /// den Kanal der Gegenseite.
    var speaker: String?

    init(id: UUID = UUID(), source: Source, text: String, t: TimeInterval,
         end: TimeInterval? = nil, speaker: String? = nil) {
        self.id = id
        self.source = source
        self.text = text
        self.t = t
        self.end = end
        self.speaker = speaker
    }
}

struct MeetingMeta: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    let date: Date
    var duration: TimeInterval
    var languageCode: String
    var summary: String?
    var summarizerName: String?
    /// Zuordnung „Sprecher 1“ → vom Nutzer vergebener Name.
    var speakerNames: [String: String]?

    /// Anzeigename für eine Sprecherkennung.
    func displayName(for speaker: String?, source: MeetingSegment.Source) -> String {
        guard source == .others else { return source.label }
        guard let speaker else { return source.label }
        return speakerNames?[speaker] ?? speaker
    }
}

/// Meetings live in `Application Support/Sprachacus/meetings/<uuid>/`:
/// `meta.json` plus `transcript.jsonl`. Every finalized segment is appended
/// immediately, so a crash during a two-hour meeting loses at most the last
/// unfinished sentence.
@MainActor
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    @Published private(set) var meetings: [MeetingMeta] = []

    private var rootDir: URL {
        let dir = AppPaths.supportDir.appendingPathComponent("meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func dir(for id: UUID) -> URL {
        let dir = rootDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func metaURL(_ id: UUID) -> URL { dir(for: id).appendingPathComponent("meta.json") }
    private func transcriptURL(_ id: UUID) -> URL { dir(for: id).appendingPathComponent("transcript.jsonl") }

    private init() {
        reload()
    }

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let contents = (try? FileManager.default.contentsOfDirectory(at: rootDir,
                                                                     includingPropertiesForKeys: nil)) ?? []
        meetings = contents.compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("meta.json")) else { return nil }
            return try? decoder.decode(MeetingMeta.self, from: data)
        }
        .sorted { $0.date > $1.date }
    }

    func create(languageCode: String) -> MeetingMeta {
        let meta = MeetingMeta(id: UUID(),
                               title: Self.defaultTitle(for: Date()),
                               date: Date(),
                               duration: 0,
                               languageCode: languageCode,
                               summary: nil,
                               summarizerName: nil)
        write(meta)
        meetings.insert(meta, at: 0)
        return meta
    }

    func update(_ meta: MeetingMeta) {
        write(meta)
        if let index = meetings.firstIndex(where: { $0.id == meta.id }) {
            meetings[index] = meta
        } else {
            meetings.insert(meta, at: 0)
        }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: dir(for: id))
        meetings.removeAll { $0.id == id }
    }

    /// Appends one finalized segment. Opens/closes the file per segment —
    /// segments arrive every few seconds, and this keeps the file consistent
    /// even if the app is killed.
    func appendSegment(_ segment: MeetingSegment, to id: UUID) {
        guard let line = try? JSONEncoder().encode(segment) else { return }
        var data = line
        data.append(0x0A) // \n
        let url = transcriptURL(id)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    func segments(for id: UUID) -> [MeetingSegment] {
        guard let raw = try? String(contentsOf: transcriptURL(id), encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return raw
            .split(separator: "\n")
            .compactMap { try? decoder.decode(MeetingSegment.self, from: Data($0.utf8)) }
            .sorted { $0.t < $1.t }
    }

    /// Speaker-labelled plain text, the input for the summarizer and the
    /// "Transkript kopieren" button.
    func transcriptText(for id: UUID) -> String {
        guard let meta = meetings.first(where: { $0.id == id }) else {
            return segments(for: id).map { "\($0.source.label): \($0.text)" }.joined(separator: "\n")
        }
        return transcriptText(for: meta)
    }

    func transcriptText(for meta: MeetingMeta) -> String {
        segments(for: meta.id)
            .map { "\(meta.displayName(for: $0.speaker, source: $0.source)): \($0.text)" }
            .joined(separator: "\n")
    }

    /// Ersetzt die Transkriptdatei — nach der Sprechertrennung, die allen
    /// Abschnitten der Gegenseite eine Kennung zuweist.
    func replaceSegments(_ segments: [MeetingSegment], for id: UUID) {
        let encoder = JSONEncoder()
        var data = Data()
        for segment in segments {
            guard let line = try? encoder.encode(segment) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: transcriptURL(id), options: .atomic)
    }

    /// Alle in einem Meeting erkannten Sprecherkennungen, in Reihenfolge des
    /// ersten Auftretens.
    func speakerIDs(for id: UUID) -> [String] {
        var seen: [String] = []
        for segment in segments(for: id) {
            if let speaker = segment.speaker, !seen.contains(speaker) { seen.append(speaker) }
        }
        return seen
    }

    /// Pfad des Mitschnitts der Gegenseite (Grundlage der Sprechertrennung).
    func systemAudioURL(for id: UUID) -> URL {
        dir(for: id).appendingPathComponent("system-audio.wav")
    }

    func markdown(for meta: MeetingMeta) -> String {
        var out = "# \(meta.title)\n\n"
        out += "\(Self.dateFormatter.string(from: meta.date)) · Dauer \(Self.durationText(meta.duration))\n\n"
        if let summary = meta.summary, !summary.isEmpty {
            out += "## Zusammenfassung\n\n\(summary)\n\n"
        }
        out += "## Transkript\n\n"
        for segment in segments(for: meta.id) {
            let name = meta.displayName(for: segment.speaker, source: segment.source)
            out += "**\(name)** (\(Self.timestamp(segment.t))): \(segment.text)\n\n"
        }
        return out
    }

    private func write(_ meta: MeetingMeta) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(meta) else { return }
        try? data.write(to: metaURL(meta.id), options: .atomic)
    }

    // MARK: - Formatting helpers

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func defaultTitle(for date: Date) -> String {
        "Meeting vom \(dateFormatter.string(from: date))"
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        durationText(seconds)
    }
}
