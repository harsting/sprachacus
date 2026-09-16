import AVFoundation
import Accelerate
import Foundation

/// Eine Transkriptionsspur eines Meetings („Ich" oder „Andere").
///
/// Der Grund für diese Schicht: Der Ergebnisstrom von `SpeechAnalyzer` kann
/// mitten im Betrieb enden. Vorher lief der Ton danach in eine tote Erkennung,
/// ohne dass es auffiel — im Betrieb ist so ein Transkript entstanden, das
/// nach einer Minute nur noch eine Seite des Gesprächs enthielt.
///
/// Der Kanal erkennt beide Ausfallarten und startet die Erkennung neu:
/// den beendeten Strom (Meldung von `Transcriber`) und die stille Blockade
/// (Ton kommt an, aber seit Längerem kein Ergebnis mehr).
final class TranscriptionChannel: @unchecked Sendable {
    let name: String

    var onSegment: ((String, TimeInterval, TimeInterval) -> Void)?
    var onPartial: ((String) -> Void)?
    /// Meldet Zustandswechsel: gesund / gestört mit Begründung.
    var onHealthChanged: ((Bool, String?) -> Void)?
    var log: ((String) -> Void)?

    private let locale: Locale
    private let vocabulary: [String]
    private let lock = NSLock()
    private var transcriber: Transcriber?
    private var running = false

    /// Bisher eingespeiste Tonsekunden — die durchgehende Zeitachse des Kanals.
    private var secondsFed: TimeInterval = 0
    /// Startpunkt der aktuellen Erkennungssitzung auf dieser Zeitachse.
    private var sessionOffset: TimeInterval = 0
    /// Lauter Ton seit dem letzten Ergebnis. Grundlage der Blockade-Erkennung.
    private var loudSecondsSinceResult: TimeInterval = 0
    /// Ton, der eintrifft, während gerade keine Sitzung offen ist (Neustart).
    /// Ohne diesen Puffer wäre alles, was in diesen Sekunden gesagt wird,
    /// ersatzlos weg — ausgerechnet in dem Moment, in dem es schon einmal
    /// gehakt hat.
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingSeconds: TimeInterval = 0
    private static let maximumPendingSeconds: TimeInterval = 30
    private var restarts = 0
    private var lastRestart = Date.distantPast
    private var healthy = true

    /// So lange darf lauter Ton ohne ein einziges Ergebnis bleiben, bevor die
    /// Erkennung als blockiert gilt. Großzügig, damit normale Gesprächspausen
    /// und langsame Erkennung nicht fälschlich einen Neustart auslösen.
    private let stallThreshold: TimeInterval
    private static let loudnessThreshold: Float = 0.004
    private static let minimumRestartInterval: TimeInterval = 3
    private static let maximumRestarts = 30

    /// - Parameter stallThreshold: So lange darf lauter Ton ohne ein einziges
    ///   Ergebnis bleiben, bevor die Erkennung als blockiert gilt.
    init(name: String, locale: Locale, vocabulary: [String] = [],
         stallThreshold: TimeInterval = 45) {
        self.name = name
        self.locale = locale
        self.vocabulary = vocabulary
        self.stallThreshold = stallThreshold
    }

    var isHealthy: Bool { lock.lock(); defer { lock.unlock() }; return healthy }
    var restartCount: Int { lock.lock(); defer { lock.unlock() }; return restarts }

    // MARK: - Lebenszyklus

    func start() async throws {
        lock.lock(); running = true; secondsFed = 0; sessionOffset = 0; lock.unlock()
        try await openSession()
    }

    private func openSession() async throws {
        // Der Zeitversatz wird fest in die Rückrufe dieser Sitzung gelegt.
        // Würde er erst beim Eintreffen eines Ergebnisses gelesen, bekämen
        // nachgereichte Abschnitte einer beendeten Sitzung den Versatz der
        // neuen. Der endgültige Wert steht erst fest, wenn klar ist, wie viel
        // gepufferter Ton dieser Sitzung vorangestellt wird — deshalb die Box.
        let offset = OffsetBox()

        let transcriber = Transcriber()
        transcriber.onStreamEnded = { [weak self] error in
            self?.handleStreamEnded(error)
        }
        try await transcriber.start(locale: locale, vocabulary: vocabulary, onPartial: { [weak self] text in
            self?.onPartial?(text)
        }, onFinalSegment: { [weak self] text, start, end in
            guard let self else { return }
            self.lock.lock(); self.loudSecondsSinceResult = 0; let base = offset.value; self.lock.unlock()
            self.onSegment?(text, base + start, base + end)
        })

        lock.lock()
        let buffered = pending
        // Der gepufferte Ton liegt vor dem jetzigen Zeitpunkt — die Sitzung
        // beginnt entsprechend früher, sonst läge alles Folgende zu spät.
        offset.value = secondsFed - pendingSeconds
        pending = []
        pendingSeconds = 0
        self.transcriber = transcriber
        self.sessionOffset = offset.value
        self.loudSecondsSinceResult = 0
        lock.unlock()

        for buffer in buffered { transcriber.feed(buffer) }
    }

    /// Wird aus dem Audio-Thread aufgerufen.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard running else { lock.unlock(); return }
        // Die Zeitachse zählt bewusst auch die Sekunden mit, in denen gerade
        // keine Sitzung offen ist (während eines Neustarts). Täte sie das
        // nicht, bekämen alle folgenden Abschnitte einen zu frühen Zeitstempel
        // und lägen dauerhaft neben der anderen Spur.
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        secondsFed += duration
        if Self.rms(buffer) > Self.loudnessThreshold {
            loudSecondsSinceResult += duration
        }
        let current = transcriber
        if current == nil, let copy = Self.copy(buffer) {
            // Bewusst eine Kopie: Der Puffer aus dem Audio-Tap gehört dem
            // System und darf über den Rückruf hinaus nicht festgehalten werden.
            pending.append(copy)
            pendingSeconds += duration
            // Puffer begrenzen: Kommt die Erkennung gar nicht zurück, darf der
            // Speicher nicht mitwachsen.
            while pendingSeconds > Self.maximumPendingSeconds, let first = pending.first {
                pendingSeconds -= Double(first.frameLength) / first.format.sampleRate
                pending.removeFirst()
            }
        }
        lock.unlock()
        current?.feed(buffer)
    }

    /// Einmal je Sekunde vom Meeting-Zeitgeber aufgerufen.
    func checkLiveness() {
        lock.lock()
        let stalled = running && loudSecondsSinceResult > stallThreshold
        let stalledFor = loudSecondsSinceResult
        lock.unlock()
        guard stalled else { return }
        log?("\(name): seit \(Int(stalledFor)) s lauter Ton ohne Ergebnis — Erkennung wird neu gestartet")
        restart(reason: "Erkennung blockiert")
    }

    func finish(timeout: TimeInterval = 12) async -> String {
        lock.lock()
        running = false
        let current = transcriber
        transcriber = nil
        // Was noch im Neustart-Puffer liegt, kommt jetzt nicht mehr an.
        let stranded = pendingSeconds
        pending = []
        pendingSeconds = 0
        lock.unlock()
        if stranded > 0.5 {
            log?("\(name): \(String(format: "%.1f", stranded)) s Ton aus einem laufenden Neustart konnten nicht mehr ausgewertet werden")
        }
        guard let current else { return "" }
        return (try? await current.finish(timeout: timeout)) ?? ""
    }

    func cancel() {
        lock.lock()
        running = false
        let current = transcriber
        transcriber = nil
        pending = []
        pendingSeconds = 0
        lock.unlock()
        current?.cancel()
    }

    // MARK: - Wiederherstellung

    private func handleStreamEnded(_ error: Error?) {
        lock.lock(); let isRunning = running; lock.unlock()
        guard isRunning else { return }
        let reason = error?.localizedDescription ?? "Strom ohne Fehler beendet"
        log?("\(name): Erkennung ausgefallen (\(reason))")
        restart(reason: reason)
    }

    private func restart(reason: String) {
        lock.lock()
        guard running, Date().timeIntervalSince(lastRestart) > Self.minimumRestartInterval else {
            lock.unlock(); return
        }
        guard restarts < Self.maximumRestarts else {
            let wasHealthy = healthy
            healthy = false
            lock.unlock()
            if wasHealthy { onHealthChanged?(false, "\(name): Erkennung dauerhaft ausgefallen") }
            return
        }
        lastRestart = Date()
        restarts += 1
        let attempt = restarts
        let old = transcriber
        transcriber = nil
        loudSecondsSinceResult = 0
        lock.unlock()

        Task { [weak self] in
            guard let self else { return }
            // Alte Sitzung abschließen statt abbrechen: Was sie noch im Puffer
            // hat, wird dadurch nachgereicht und geht nicht verloren.
            if let old {
                _ = try? await old.finish(timeout: 5)
            }
            do {
                try await self.openSession()
                self.lock.lock(); let wasUnhealthy = !self.healthy; self.healthy = true; self.lock.unlock()
                self.log?("\(self.name): Erkennung neu gestartet (Versuch \(attempt))")
                if wasUnhealthy { self.onHealthChanged?(true, nil) }
            } catch {
                self.lock.lock(); self.healthy = false; self.lock.unlock()
                self.log?("\(self.name): Neustart fehlgeschlagen: \(error.localizedDescription)")
                self.onHealthChanged?(false, "\(self.name): Erkennung ausgefallen")
                // Erneut versuchen — der Dienst ist oft nach Sekunden wieder da.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.restart(reason: "erneuter Versuch")
            }
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                          frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let source = buffer.floatChannelData, let target = copy.floatChannelData {
            for channel in 0..<channels {
                target[channel].update(from: source[channel], count: frames)
            }
            return copy
        }
        if let source = buffer.int16ChannelData, let target = copy.int16ChannelData {
            for channel in 0..<channels {
                target[channel].update(from: source[channel], count: frames)
            }
            return copy
        }
        return nil
    }

    /// Hält den Zeitversatz einer Sitzung, der erst nach dem Start feststeht.
    private final class OffsetBox {
        var value: TimeInterval = 0
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0 else { return 0 }
        if let data = buffer.floatChannelData?[0] {
            var value: Float = 0
            vDSP_rmsqv(data, 1, &value, vDSP_Length(buffer.frameLength))
            return value
        }
        if let data = buffer.int16ChannelData?[0] {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) {
                let v = Float(data[i]) / 32768
                sum += v * v
            }
            return (sum / Float(buffer.frameLength)).squareRoot()
        }
        return 0
    }
}
