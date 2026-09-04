import FluidAudio
import Foundation

/// Zerlegt den Mitschnitt der Gegenseite in Sprecherabschnitte und ordnet
/// jedem Transkript-Abschnitt den Sprecher mit der größten zeitlichen
/// Überlappung zu.
///
/// Läuft vollständig lokal. Die Core-ML-Modelle lädt FluidAudio beim ersten
/// Gebrauch einmalig herunter und nutzt sie danach offline.
enum SpeakerDiarizer {
    struct DiarizerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Kürzere Abschnitte sind meist Einwürfe oder Rauschen und würden die
    /// Zuordnung eher verschlechtern.
    private static let minimumSegmentDuration: Float = 0.6

    static var modelsReady: Bool {
        let directory = OfflineDiarizerModels.defaultModelsDirectory()
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return !contents.isEmpty
    }

    /// - Returns: die Transkript-Abschnitte mit gesetzter Sprecherkennung.
    static func assignSpeakers(to segments: [MeetingSegment],
                               audioURL: URL,
                               onProgress: @escaping @Sendable (String) -> Void = { _ in })
        async throws -> [MeetingSegment] {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw DiarizerError(message: "Kein Mitschnitt der Gegenseite vorhanden")
        }
        let others = segments.filter { $0.source == .others }
        guard !others.isEmpty else { return segments }

        onProgress(modelsReady ? "Erkenne Sprecher…" : "Lade Sprecher-Modell (einmalig)…")
        let manager = OfflineDiarizerManager()
        try await manager.prepareModels()

        onProgress("Erkenne Sprecher…")
        let result = try await manager.process(audioURL)
        let raw = result.segments
        NSLog("Diarizer: \(raw.count) Abschnitte, \(Set(raw.map(\.speakerId)).count) Sprecher erkannt")
        let speakerSegments = raw.filter { $0.durationSeconds >= minimumSegmentDuration }
        guard !speakerSegments.isEmpty else {
            throw DiarizerError(message: "Keine Sprecherabschnitte erkannt")
        }

        // Kennungen in Reihenfolge des ersten Auftretens durchnummerieren,
        // damit „Sprecher 1“ auch der zuerst Sprechende ist.
        var labels: [String: String] = [:]
        for segment in speakerSegments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            if labels[segment.speakerId] == nil {
                labels[segment.speakerId] = "Sprecher \(labels.count + 1)"
            }
        }

        return segments.map { segment in
            guard segment.source == .others else { return segment }
            var updated = segment
            let end = segment.end ?? (segment.t + 2)
            if let best = bestMatch(start: segment.t, end: end, in: speakerSegments) {
                updated.speaker = labels[best]
            }
            return updated
        }
    }

    /// Sprecher mit der größten Überlappung im Zeitfenster des Abschnitts.
    private static func bestMatch(start: TimeInterval, end: TimeInterval,
                                  in speakerSegments: [TimedSpeakerSegment]) -> String? {
        var overlapPerSpeaker: [String: Double] = [:]
        for candidate in speakerSegments {
            let overlap = min(end, Double(candidate.endTimeSeconds))
                        - max(start, Double(candidate.startTimeSeconds))
            if overlap > 0 {
                overlapPerSpeaker[candidate.speakerId, default: 0] += overlap
            }
        }
        return overlapPerSpeaker.max { $0.value < $1.value }?.key
    }
}
