import Foundation
import Speech
import AVFoundation

/// On-device streaming transcription via the macOS 26 SpeechAnalyzer API.
/// Audio is streamed while recording, so the final transcript is available
/// almost immediately after the user stops.
final class Transcriber {
    struct TranscriberError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var recognizerTask: Task<String, Error>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    /// Meldet, dass der Ergebnisstrom geendet hat — mit Fehler oder einfach so.
    /// Ohne diese Meldung liefe Ton in eine tote Erkennung, ohne dass es
    /// jemand merkt (genau so ist im Betrieb ein halbes Transkript entstanden).
    var onStreamEnded: ((Error?) -> Void)?
    /// Bisher erkannter Text, auch von außen lesbar — damit ein abgebrochener
    /// Abschluss noch liefert, was bereits verstanden wurde.
    private let textLock = NSLock()
    private var collectedText = ""
    /// Ob überhaupt Ton eingespeist wurde. Ohne Ton hat der Analyzer nichts zu
    /// finalisieren und der Abschluss kann endlos warten.
    private var fedFrames: UInt64 = 0
    /// Verhindert, dass ein planmäßiger Abschluss als Ausfall gemeldet wird.
    private var isFinishing = false

    // MARK: - Model management

    static func isModelInstalled(locale: Locale) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// Downloads the on-device model for `locale` if missing. One-time per language.
    static func ensureModel(locale: Locale, onProgress: @escaping (Double) -> Void) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw TranscriberError(message: "Sprache \(locale.identifier) wird nicht unterstützt")
        }
        if await isModelInstalled(locale: locale) { return }

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [])
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return // nothing to download
        }
        let progress = request.progress
        let poller = Task {
            while !Task.isCancelled {
                onProgress(progress.fractionCompleted)
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { poller.cancel() }
        try await request.downloadAndInstall()
    }

    // MARK: - Session

    /// - Parameters:
    ///   - onFinalSegment: fires for every finalized chunk while the session
    ///     runs (meeting mode appends these live) together with its position
    ///     on the audio timeline; `finish()` still returns the full text.
    func start(locale: Locale,
               onPartial: @escaping (String) -> Void,
               onFinalSegment: ((String, TimeInterval, TimeInterval) -> Void)? = nil) async throws {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard analyzerFormat != nil else {
            throw TranscriberError(message: "Kein kompatibles Audioformat gefunden")
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = continuation

        recognizerTask = Task { [weak self] in
            var finalText = ""
            var failure: Error?
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalText += text
                        self?.textLock.lock()
                        self?.collectedText = finalText
                        self?.textLock.unlock()
                        let segment = Self.normalize(text)
                        if !segment.isEmpty {
                            let range = result.range
                            onFinalSegment?(segment, range.start.seconds, range.end.seconds)
                        }
                    } else {
                        onPartial(text)
                    }
                }
            } catch {
                failure = error
            }
            // Ende des Stroms — ob planmäßig oder nicht — nach außen melden.
            if let self, !self.isFinishing {
                self.onStreamEnded?(failure)
            }
            return finalText
        }

        try await analyzer.start(inputSequence: stream)
    }

    /// Called from the audio tap thread — converts to the analyzer format and yields.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let analyzerFormat, let inputBuilder else { return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
        }
        guard let converter else { return }

        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }

        var served = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if served {
                outStatus.pointee = .noDataNow
                return nil
            }
            served = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return }
        fedFrames += UInt64(out.frameLength)
        inputBuilder.yield(AnalyzerInput(buffer: out))
    }

    /// Stops input, flushes the analyzer and returns the final transcript.
    ///
    /// Der Abschluss läuft gegen ein Zeitlimit: Bleibt der Analyzer hängen —
    /// etwa wenn gar nicht gesprochen wurde —, wird er abgebrochen und das
    /// bis dahin Erkannte zurückgegeben, statt endlos zu warten.
    func finish(timeout: TimeInterval = 12) async throws -> String {
        isFinishing = true
        inputBuilder?.finish()
        let analyzer = self.analyzer
        let task = self.recognizerTask

        guard fedFrames > 0 else {
            task?.cancel()
            await analyzer?.cancelAndFinishNow()
            cleanup()
            return ""
        }

        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                try? await analyzer?.finalizeAndFinishThroughEndOfInput()
                _ = try? await task?.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if !completed {
            NSLog("Transcriber: Abschluss nach \(Int(timeout)) s abgebrochen — liefere bisher Erkanntes")
            task?.cancel()
            await analyzer?.cancelAndFinishNow()
        }
        textLock.lock()
        let text = collectedText
        textLock.unlock()
        cleanup()
        return Self.normalize(text)
    }

    func cancel() {
        isFinishing = true
        recognizerTask?.cancel()
        inputBuilder?.finish()
        let analyzer = self.analyzer
        Task { await analyzer?.cancelAndFinishNow() }
        cleanup()
    }

    private func cleanup() {
        analyzer = nil
        inputBuilder = nil
        recognizerTask = nil
        converter = nil
        analyzerFormat = nil
        fedFrames = 0
    }

    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
