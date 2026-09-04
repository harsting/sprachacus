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
    /// Optionaler Mitschnitt exakt in der Analyse-Abtastrate. Dadurch teilen
    /// Datei und Transkript dieselbe Zeitachse — Voraussetzung dafür, später
    /// Sprecherabschnitte den Sätzen zuzuordnen.
    private var recordingFile: AVAudioFile?
    private let recordingLock = NSLock()

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
    ///   - recordTo: schreibt den analysierten Ton zusätzlich als Datei mit.
    func start(locale: Locale,
               onPartial: @escaping (String) -> Void,
               onFinalSegment: ((String, TimeInterval, TimeInterval) -> Void)? = nil,
               recordTo url: URL? = nil) async throws {
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

        if let url, let format = analyzerFormat {
            do {
                // commonFormat/interleaved mitgeben: Sonst erwartet AVAudioFile
                // Float32-Puffer, und das Schreiben der Int16-Puffer schlägt
                // still fehl — die Datei bliebe leer.
                recordingFile = try AVAudioFile(forWriting: url,
                                                settings: format.settings,
                                                commonFormat: format.commonFormat,
                                                interleaved: format.isInterleaved)
            } catch {
                NSLog("Transcriber: Mitschnitt konnte nicht angelegt werden: \(error.localizedDescription)")
            }
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = continuation

        recognizerTask = Task {
            var finalText = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalText += text
                    let segment = Self.normalize(text)
                    if !segment.isEmpty {
                        let range = result.range
                        onFinalSegment?(segment, range.start.seconds, range.end.seconds)
                    }
                } else {
                    onPartial(text)
                }
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
        if let recordingFile {
            recordingLock.lock()
            try? recordingFile.write(from: out)
            recordingLock.unlock()
        }
        inputBuilder.yield(AnalyzerInput(buffer: out))
    }

    /// Stops input, flushes the analyzer and returns the final transcript.
    func finish() async throws -> String {
        inputBuilder?.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        let text = try await recognizerTask?.value ?? ""
        cleanup()
        return Self.normalize(text)
    }

    func cancel() {
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
        recordingLock.lock()
        recordingFile = nil
        recordingLock.unlock()
    }

    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
