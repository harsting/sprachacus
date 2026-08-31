import AppKit
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

    private var meeting: MeetingMeta?
    private var startedAt = Date()
    private var micTranscriber: Transcriber?
    private var systemTranscriber: Transcriber?
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

                let mic = Transcriber()
                let system = Transcriber()
                micTranscriber = mic
                systemTranscriber = system

                try await mic.start(locale: locale, onPartial: { [weak self] text in
                    Task { @MainActor in self?.partialMe = text }
                }, onFinalSegment: { [weak self] text in
                    Task { @MainActor in self?.record(text, from: .me) }
                })
                try await system.start(locale: locale, onPartial: { [weak self] text in
                    Task { @MainActor in self?.partialOthers = text }
                }, onFinalSegment: { [weak self] text in
                    Task { @MainActor in self?.record(text, from: .others) }
                })
                guard isRecording else {
                    mic.cancel(); system.cancel()
                    return
                }

                recorder.onRestartFailed = { [weak self] _ in
                    Task { @MainActor in self?.statusMessage = "Mikrofon verloren — Meeting beenden und neu starten" }
                }
                try recorder.start(onBuffer: { [weak mic] buffer in
                    mic?.feed(buffer)
                }, onLevel: { [weak self] level in
                    Task { @MainActor in self?.micLevel = level }
                })

                capture.onBuffer = { [weak system] buffer in
                    system?.feed(buffer)
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

            statusMessage = "Fasse zusammen…"
            do {
                let summary = try await MeetingSummarizer.summarize(transcript: transcript,
                                                                    languageCode: updated.languageCode)
                updated.summary = summary.text
                updated.summarizerName = summary.providerName
            } catch {
                NSLog("Meeting summary failed: \(error)")
                statusMessage = "Zusammenfassung fehlgeschlagen — Transkript ist gespeichert"
            }
            MeetingStore.shared.update(updated)

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

    private func record(_ text: String, from source: MeetingSegment.Source) {
        guard let meeting, !text.isEmpty else { return }
        let segment = MeetingSegment(source: source,
                                     text: text,
                                     t: Date().timeIntervalSince(startedAt))
        segments.append(segment)
        switch source {
        case .me: partialMe = ""
        case .others: partialOthers = ""
        }
        MeetingStore.shared.appendSegment(segment, to: meeting.id)
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
        // finish() flushes the analyzers, so trailing speech still lands in the
        // transcript via onFinalSegment.
        if let micTranscriber { _ = try? await micTranscriber.finish() }
        if let systemTranscriber { _ = try? await systemTranscriber.finish() }
        micTranscriber = nil
        systemTranscriber = nil
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
