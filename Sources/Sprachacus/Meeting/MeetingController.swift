import AppKit
import AVFoundation
import Foundation

/// Records a meeting: the microphone ("Ich") and the system audio mix
/// ("Andere") run through two independent SpeechAnalyzer sessions, so the
/// transcript keeps speaker separation even with headphones on.
@MainActor
final class MeetingController: ObservableObject {
    static let shared = MeetingController()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var segments: [MeetingSegment] = []
    @Published private(set) var partialMe = ""
    @Published private(set) var partialOthers = ""
    @Published private(set) var isSummarizing = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var systemAudioActive = false
    /// Ton läuft über interne Lautsprecher — das Mikrofon hört die Gegenseite mit.
    @Published private(set) var echoRisk = false
    @Published private(set) var inputDeviceName: String?
    /// Meldung, wenn eine Spur dauerhaft ausgefallen ist — darf nicht still bleiben.
    @Published private(set) var channelWarning: String?

    private var meeting: MeetingMeta?
    private var startedAt = Date()
    private var micChannel: TranscriptionChannel?
    private var systemChannel: TranscriptionChannel?
    private var audioWriter: WavWriter?
    private var logHandle: FileHandle?
    private let recorder = AudioRecorder()
    private let capture = SystemAudioCapture()
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var captureRestarts = 0

    private var languageCode: String { Settings.shared.localeIdentifier }

    // MARK: - Start

    func start() {
        guard !isRecording else { return }
        guard confirmLegalNotice() else { return }
        guard ensureScreenRecordingPermission() else { return }

        let locale = Locale(identifier: languageCode)
        statusMessage = nil
        segments = []
        partialMe = ""
        partialOthers = ""
        elapsed = 0
        captureRestarts = 0
        isRecording = true

        Task { @MainActor in
            do {
                if !(await Transcriber.isModelInstalled(locale: locale)) {
                    statusMessage = "Lade Sprachmodell…"
                    try await Transcriber.ensureModel(locale: locale) { _ in }
                }
                guard isRecording else { return }

                let meeting = MeetingStore.shared.create(languageCode: languageCode)
                self.meeting = meeting
                startedAt = Date()

                openLog(for: meeting.id)
                appendLog("Meeting gestartet — Sprache \(languageCode), Mikrofon \(AudioDevices.name(forUID: Settings.shared.inputDeviceUID ?? "") ?? "Systemstandard")")

                // Mitschnitt der Gegenseite: Grundlage der Sprechertrennung.
                // Läuft bewusst unabhängig von der Erkennung — fällt die aus,
                // ist der Ton trotzdem vollständig erhalten.
                if let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                              channels: 1, interleaved: false) {
                    audioWriter = WavWriter(url: MeetingStore.shared.systemAudioURL(for: meeting.id),
                                            format: format)
                }

                // Eigene Begriffe (Namen, Kürzel, Standnummern) gehen der
                // Erkennung sonst am ehesten verloren.
                let vocabulary = Settings.shared.vocabularyTerms
                if !vocabulary.isEmpty {
                    appendLog("Vokabular aktiv: \(vocabulary.count) Begriffe")
                }
                let mic = TranscriptionChannel(name: "Ich", locale: locale, vocabulary: vocabulary)
                let system = TranscriptionChannel(name: "Andere", locale: locale, vocabulary: vocabulary)
                micChannel = mic
                systemChannel = system
                for (channel, source) in [(mic, MeetingSegment.Source.me), (system, .others)] {
                    channel.log = { [weak self] message in
                        Task { @MainActor in self?.appendLog(message) }
                    }
                    channel.onSegment = { [weak self] text, start, end in
                        Task { @MainActor in self?.record(text, from: source, start: start, end: end) }
                    }
                    channel.onHealthChanged = { [weak self] healthy, message in
                        Task { @MainActor in
                            self?.channelWarning = healthy ? nil : message
                            if let message { self?.appendLog("WARNUNG: \(message)") }
                        }
                    }
                }
                mic.onPartial = { [weak self] text in Task { @MainActor in self?.partialMe = text } }
                system.onPartial = { [weak self] text in Task { @MainActor in self?.partialOthers = text } }

                try await mic.start()
                try await system.start()
                guard isRecording else {
                    mic.cancel(); system.cancel()
                    return
                }

                recorder.onRestartFailed = { [weak self] _ in
                    Task { @MainActor in self?.statusMessage = "Mikrofon verloren — Meeting beenden und neu starten" }
                }
                try recorder.start(
                    deviceUID: Settings.shared.inputDeviceUID,
                    onBuffer: { [weak mic] buffer in mic?.feed(buffer) },
                    onLevel: { [weak self] level in
                        Task { @MainActor in self?.micLevel = level }
                    })
                updateEchoRisk()

                capture.onBuffer = { [weak self, weak system] buffer in
                    system?.feed(buffer)
                    self?.audioWriter?.write(buffer)
                }
                capture.onLevel = { [weak self] level in
                    Task { @MainActor in self?.systemLevel = level }
                }
                capture.onStopped = { [weak self] error in
                    Task { @MainActor in self?.handleCaptureStopped(error) }
                }
                try await capture.start()
                systemAudioActive = true

                beginActivity()
                startTimer()
                statusMessage = nil
                MeetingWindowController.shared.show()
            } catch {
                NSLog("Meeting start failed: \(error)")
                statusMessage = error.localizedDescription
                await teardownCapture()
                isRecording = false
                showAlert(title: "Meeting konnte nicht gestartet werden",
                          message: error.localizedDescription)
            }
        }
    }

    // MARK: - Stop

    func stopAndSummarize() {
        guard isRecording, let meeting else { return }
        isRecording = false
        stopTimer()
        let duration = Date().timeIntervalSince(startedAt)

        Task { @MainActor in
            isSummarizing = true
            statusMessage = "Schließe Transkription ab…"
            await teardownCapture()
            // The analyzers' trailing segments arrive through onFinalSegment on
            // the main actor — give those a moment to land before reading the
            // transcript back, otherwise the last sentences are missing.
            try? await Task.sleep(nanoseconds: 400_000_000)

            var updated = meeting
            updated.duration = duration
            MeetingStore.shared.update(updated)

            let transcript = MeetingStore.shared.transcriptText(for: meeting.id)
            guard !transcript.isEmpty else {
                statusMessage = nil
                isSummarizing = false
                self.meeting = nil
                MeetingWindowController.shared.hide()
                showAlert(title: "Nichts aufgezeichnet",
                          message: "Im Meeting wurde keine Sprache erkannt. Das leere Meeting wurde verworfen.")
                MeetingStore.shared.delete(meeting.id)
                return
            }

            // Sprechertrennung: Der Mitschnitt der Gegenseite wird in
            // Sprecherabschnitte zerlegt und den Sätzen zugeordnet. Schlägt
            // das fehl, bleibt das Transkript unverändert erhalten.
            if Settings.shared.speakerDiarization {
                do {
                    let stored = MeetingStore.shared.segments(for: meeting.id)
                    let assigned = try await SpeakerDiarizer.assignSpeakers(
                        to: stored,
                        audioURL: MeetingStore.shared.systemAudioURL(for: meeting.id),
                        onProgress: { [weak self] text in
                            Task { @MainActor in self?.statusMessage = text }
                        })
                    MeetingStore.shared.replaceSegments(assigned, for: meeting.id)
                } catch {
                    NSLog("Sprechertrennung fehlgeschlagen: \(error.localizedDescription)")
                    statusMessage = "Sprechertrennung nicht möglich — Transkript bleibt erhalten"
                }
                if !Settings.shared.keepMeetingAudio {
                    try? FileManager.default.removeItem(at: MeetingStore.shared.systemAudioURL(for: meeting.id))
                }
            }

            statusMessage = "Fasse zusammen…"
            let finalTranscript = MeetingStore.shared.transcriptText(for: updated)
            do {
                let summary = try await MeetingSummarizer.summarize(transcript: finalTranscript,
                                                                    languageCode: updated.languageCode)
                updated.summary = summary.text
                updated.summarizerName = summary.providerName
            } catch {
                NSLog("Meeting summary failed: \(error)")
                statusMessage = "Zusammenfassung fehlgeschlagen — Transkript ist gespeichert"
            }
            MeetingStore.shared.update(updated)

            appendLog("Zusammenfassung abgeschlossen")
            closeLog()
            isSummarizing = false
            self.meeting = nil
            MeetingWindowController.shared.hide()
            MainWindowController.shared.show(tab: .meetings)
        }
    }

    /// Re-runs the summary for a stored meeting (also used by the Meetings tab).
    func resummarize(_ meta: MeetingMeta) async {
        var updated = meta
        let transcript = MeetingStore.shared.transcriptText(for: meta.id)
        do {
            let summary = try await MeetingSummarizer.summarize(transcript: transcript,
                                                                languageCode: meta.languageCode)
            updated.summary = summary.text
            updated.summarizerName = summary.providerName
            MeetingStore.shared.update(updated)
        } catch {
            showAlert(title: "Zusammenfassung fehlgeschlagen", message: error.localizedDescription)
        }
    }

    // MARK: - Internals

    // MARK: - Protokoll

    /// Schreibt den Verlauf neben das Transkript. Bei einem Ausfall wie dem
    /// vom 16.09. lässt sich damit nachvollziehen, wann und warum eine Spur
    /// weggebrochen ist — NSLog ist aus dieser App nicht auslesbar.
    private func openLog(for id: UUID) {
        let url = MeetingStore.shared.logURL(for: id)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
    }

    private func appendLog(_ message: String) {
        NSLog("Meeting: \(message)")
        guard let logHandle else { return }
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        logHandle.write(Data(line.utf8))
    }

    private func closeLog() {
        try? logHandle?.close()
        logHandle = nil
    }

    private func record(_ text: String, from source: MeetingSegment.Source,
                        start: TimeInterval, end: TimeInterval) {
        guard let meeting, !text.isEmpty else { return }
        // Zeitachse der Tonspur, nicht Wanduhr — nur so passen Transkript und
        // Sprechertrennung zusammen.
        let time = start.isFinite ? start : Date().timeIntervalSince(startedAt)
        // Sicherheitsnetz: Läuft der Ton über Lautsprecher, hört das Mikrofon
        // die Gegenseite mit. Die Echo-Unterdrückung fängt das meist ab; was
        // durchkommt, würde sonst als eigene Wortmeldung im Transkript stehen.
        // Nur wenn der Ton über Lautsprecher läuft, kann das Mikrofon die
        // Gegenseite überhaupt mithören. Mit Kopfhörern würde der Filter nur
        // echte eigene Sätze verwerfen — etwa wenn man wiederholt, was der
        // andere gerade gesagt hat.
        if source == .me, echoRisk, isEchoOfOthers(text, at: time) {
            // Ohne Wortlaut: Das Protokoll liegt neben dem Transkript und soll
            // keine Gesprächsinhalte doppeln.
            appendLog("Mikrofon-Abschnitt als Echo der Gegenseite verworfen (\(Self.words(text).count) Wörter, bei \(Int(time)) s)")
            partialMe = ""
            return
        }
        let segment = MeetingSegment(source: source,
                                     text: text,
                                     t: time,
                                     end: end.isFinite ? end : nil)
        // Nach Zeit einsortieren statt anhängen: Die beiden Spuren melden ihre
        // Abschnitte unabhängig voneinander und unterschiedlich schnell. Beim
        // Anhängen stünde im Livefenster die Antwort vor der Frage, sobald zwei
        // Sätze dicht aufeinander folgen oder jemand dazwischenredet.
        let position = segments.lastIndex { $0.t <= time }.map { $0 + 1 } ?? 0
        segments.insert(segment, at: position)
        switch source {
        case .me: partialMe = ""
        case .others: partialOthers = ""
        }
        MeetingStore.shared.appendSegment(segment, to: meeting.id)
    }

    /// Vergleicht ein Mikrofon-Segment mit den letzten Beiträgen der Gegenseite.
    /// Bewusst streng eingestellt: Ein fälschlich verworfener eigener Satz
    /// wäre schlimmer als ein durchgerutschtes Echo.
    private func isEchoOfOthers(_ text: String, at time: TimeInterval) -> Bool {
        let words = Self.words(text)
        guard words.count >= 5 else { return false }
        for segment in segments.reversed() where segment.source == .others {
            guard time - segment.t < 15 else { break }
            // Ein Echo klingt gleichzeitig mit dem Original, nicht danach:
            // Es muss in dessen Zeitfenster fallen. Was der andere längst
            // gesagt hat und ich jetzt wiederhole, ist meine eigene Aussage.
            guard time <= (segment.end ?? segment.t) + 2 else { continue }
            if Self.similarity(words, Self.words(segment.text)) > 0.8 { return true }
        }
        return false
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 })
    }

    /// Dice-Koeffizient — toleriert die üblichen Abweichungen zweier
    /// Erkennungsläufe desselben Tons.
    private static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return 2.0 * Double(a.intersection(b).count) / Double(a.count + b.count)
    }

    /// Prüft, ob der Ton gerade über interne Lautsprecher läuft.
    private func updateEchoRisk() {
        echoRisk = AudioDevices.defaultOutputIsBuiltInSpeaker()
        inputDeviceName = Settings.shared.inputDeviceUID.flatMap { AudioDevices.name(forUID: $0) }
    }

    /// SCK stops itself on display reconfiguration, screen lock or a revoked
    /// grant — rebuild the stream (the old display reference may be stale).
    private func handleCaptureStopped(_ error: Error) {
        guard isRecording else { return }
        systemAudioActive = false
        guard captureRestarts < 5 else {
            statusMessage = "System-Audio verloren — nur noch Mikrofon"
            return
        }
        captureRestarts += 1
        statusMessage = "System-Audio unterbrochen, starte neu…"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard isRecording else { return }
            do {
                try await capture.start()
                systemAudioActive = true
                statusMessage = nil
            } catch {
                statusMessage = "System-Audio verloren — nur noch Mikrofon"
            }
        }
    }

    private func teardownCapture() async {
        recorder.stop()
        capture.stop()
        endActivity()
        audioWriter?.close()
        audioWriter = nil
        // finish() leert die Analyzer, damit auch der letzte Satz noch über
        // onSegment im Transkript landet.
        if let micChannel { _ = await micChannel.finish() }
        if let systemChannel { _ = await systemChannel.finish() }
        appendLog("Aufzeichnung beendet — Neustarts: Ich \(micChannel?.restartCount ?? 0), Andere \(systemChannel?.restartCount ?? 0)")
        micChannel = nil
        systemChannel = nil
        systemAudioActive = false
        micLevel = 0
        systemLevel = 0
        partialMe = ""
        partialOthers = ""
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
                // Kopfhörer abgenommen? Dann wechselt macOS auf Lautsprecher.
                if Int(self.elapsed) % 5 == 0 { self.updateEchoRisk() }
                // Blockierte Erkennung erkennen und neu starten.
                self.micChannel?.checkLiveness()
                self.systemChannel?.checkLiveness()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func beginActivity() {
        endActivity()
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Meeting-Aufzeichnung läuft"
        )
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    // MARK: - Gates

    private func confirmLegalNotice() -> Bool {
        guard !Settings.shared.meetingLegalNoticeAccepted else { return true }
        let alert = NSAlert()
        alert.messageText = "Hinweis zur Aufzeichnung"
        alert.informativeText = """
        Sprachacus zeichnet Mikrofon und System-Audio auf und transkribiert beides lokal \
        auf diesem Mac.

        Das heimliche Aufzeichnen des nicht öffentlich gesprochenen Wortes ist in Deutschland \
        strafbar (§ 201 StGB). Informiere alle Teilnehmenden und hole ihr Einverständnis ein, \
        bevor du aufzeichnest.
        """
        alert.addButton(withTitle: "Verstanden")
        alert.addButton(withTitle: "Abbrechen")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        Settings.shared.meetingLegalNoticeAccepted = true
        return true
    }

    private func ensureScreenRecordingPermission() -> Bool {
        guard !SystemAudioCapture.hasPermission else { return true }
        SystemAudioCapture.requestPermission()
        showAlert(
            title: "Berechtigung für System-Audio nötig",
            message: """
            Damit Sprachacus hören kann, was die anderen Teilnehmenden sagen, braucht es die \
            Freigabe „Bildschirm- & Systemaudioaufnahme“.

            Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme \
            → Sprachacus aktivieren, dann Sprachacus neu starten und das Meeting erneut starten.

            Hinweis: Während der Aufzeichnung zeigt macOS dauerhaft ein lila Aufnahme-Symbol in \
            der Menüleiste — das ist systemseitig und lässt sich nicht abschalten.
            """
        )
        return false
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
