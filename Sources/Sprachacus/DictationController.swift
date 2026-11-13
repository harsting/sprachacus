import AppKit
import Foundation

/// The heart of the app: IDLE → RECORDING → PROCESSING → IDLE.
/// Right-Option toggles, Escape cancels. Nothing may strand the machine
/// outside IDLE — every pipeline path funnels through `finishToIdle`.
@MainActor
final class DictationController {
    enum State {
        case idle
        case recording
        case processing
    }

    /// What the finished transcript is used for.
    enum SessionMode: Equatable {
        case dictation
        case assist(context: String?)
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((State) -> Void)?

    /// A second tap this soon after the first is a double-tap (⌥⌥), not a stop.
    private static let doubleTapWindow: TimeInterval = 0.45

    private var mode: SessionMode = .dictation
    private var recordingStartedAt = Date.distantPast

    let overlay = OverlayController()
    private let recorder = AudioRecorder()
    private var transcriber = Transcriber()
    private let paster = Paster()
    /// Fängt den Ton auf, bis die Erkennung bereit ist.
    private let feed = BufferedAudioFeed()
    private var activity: NSObjectProtocol?
    /// Laufende Verarbeitung, damit sie sich abbrechen lässt.
    private var pipelineTask: Task<Void, Never>?

    var locale: Locale { Locale(identifier: Settings.shared.localeIdentifier) }

    func toggle() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            // ⌥⌥: a second tap right after starting upgrades the running
            // session to assist mode instead of stopping it — no audio is lost.
            if mode == .dictation, Date().timeIntervalSince(recordingStartedAt) < Self.doubleTapWindow {
                upgradeToAssist()
            } else {
                stopAndProcess()
            }
        case .processing:
            break // ignore taps while the pipeline runs
        }
    }

    /// Bricht Aufnahme oder Verarbeitung ab. Während der Verarbeitung ist das
    /// die Rettungsleine, falls die Erkennung einmal nicht zurückkommt.
    func cancel() {
        switch state {
        case .idle:
            return
        case .recording:
            recorder.stop()
            feed.detach()
            transcriber.cancel()
            endActivity()
            overlay.hide()
        case .processing:
            pipelineTask?.cancel()
            transcriber.cancel()
            overlay.flash(.error("Abgebrochen"), duration: 1.0)
        }
        pipelineTask = nil
        mode = .dictation
        state = .idle
    }

    private func upgradeToAssist() {
        // Freeze the clipboard now — the user may copy something else while speaking.
        let context = NSPasteboard.general.string(forType: .string)
        mode = .assist(context: context)
        overlay.setPhase(.assistRecording)
    }

    // MARK: - Pipeline

    private func startRecording() {
        guard Permissions.accessibilityGranted else {
            overlay.flash(.error("Bedienungshilfen-Freigabe fehlt (Systemeinstellungen)"), duration: 2.5)
            Permissions.requestAccessibility()
            return
        }
        state = .recording
        mode = .dictation
        recordingStartedAt = Date()
        let locale = self.locale
        Task { @MainActor in
            do {
                // Zuerst das Mikrofon — und zwar bevor irgendetwas anderes
                // passiert. Das Öffnen der Erkennung dauert spürbar; vorher
                // begann die Aufnahme erst danach und die ersten Worte
                // fehlten. Der Ton wartet so lange im Puffer.
                self.feed.detach()
                try self.recorder.start(
                    preferredUIDs: Settings.shared.inputDevicePriority,
                    onBuffer: { [feed] buffer in feed.feed(buffer) },
                    onLevel: { [weak self] level in
                        Task { @MainActor in self?.overlay.model.pushLevel(level) }
                    }
                )
                self.beginActivity()
                self.overlay.show(phase: .recording)

                // Die lokale KI-Korrektur schon einmal anwärmen — sie wird
                // gleich gebraucht, und kalt kostet sie spürbar Zeit.
                FoundationModelsRefiner.prewarm(languageCode: locale.identifier)

                if !(await Transcriber.isModelInstalled(locale: locale)) {
                    overlay.show(phase: .downloading(0))
                    try await Transcriber.ensureModel(locale: locale) { [weak self] progress in
                        Task { @MainActor in
                            if case .downloading = self?.overlay.model.phase {
                                self?.overlay.setPhase(.downloading(progress))
                            }
                        }
                    }
                }
                guard self.state == .recording else { return } // cancelled during download

                let transcriber = Transcriber()
                self.transcriber = transcriber
                try await transcriber.start(locale: locale,
                                            vocabulary: Settings.shared.vocabularyTerms) { _ in
                    // Live partials available here if we ever want a text preview.
                }
                guard self.state == .recording else {
                    transcriber.cancel()
                    self.recorder.stop()
                    self.endActivity()
                    return
                }
                // Alles, was seit dem Tastendruck gesprochen wurde, nachreichen.
                self.feed.attach(transcriber)
            } catch {
                NSLog("startRecording failed: \(error)")
                self.recorder.stop()
                self.feed.detach()
                self.transcriber.cancel()
                self.endActivity()
                self.overlay.flash(.error(error.localizedDescription), duration: 2.0)
                self.state = .idle
            }
        }
    }

    private func stopAndProcess() {
        let mode = self.mode
        state = .processing
        overlay.show(phase: .processing("Transkribiere…"))
        recorder.stop()
        feed.detach()
        endActivity()
        let transcriber = self.transcriber
        let languageCode = Settings.shared.localeIdentifier

        // Letzte Rückfallebene: Sollte irgendein Schritt trotz eigener
        // Zeitlimits hängen, bricht die Verarbeitung von selbst ab, statt die
        // App unbedienbar zu lassen.
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard let self, !Task.isCancelled, self.state == .processing else { return }
            NSLog("Dictation: Verarbeitung nach 90 s abgebrochen")
            self.overlay.flash(.error("Verarbeitung abgebrochen"), duration: 2.0)
            self.cancel()
        }

        pipelineTask = Task { @MainActor in
            defer { watchdog.cancel() }
            do {
                let raw = try await transcriber.finish()
                // Nach jedem längeren Schritt prüfen, ob der Nutzer abgebrochen
                // hat — sonst würde noch eingefügt, was er verworfen hat.
                guard !Task.isCancelled, self.state == .processing else { return }
                guard !raw.isEmpty else {
                    // Mit dem Grund, wenn er bekannt ist: Bei geschlossenem
                    // Deckel liefert das eingebaute Mikrofon digitale Stille,
                    // ohne sich irgendwie auffällig zu verhalten.
                    let reason = self.recorder.lastDeviceWasBuiltIn && AudioDevices.lidIsClosed()
                        ? "Deckel zu — Mikrofon stumm"
                        : "Nichts verstanden"
                    self.overlay.flash(.error(reason), duration: reason.count > 20 ? 2.5 : 1.2)
                    self.finishToIdle()
                    return
                }
                switch mode {
                case .dictation:
                    self.overlay.setPhase(.processing("Optimiere…"))
                    // Bei langen Diktaten dauert die Korrektur spürbar. Ein
                    // mitlaufender Zähler zeigt, dass gearbeitet wird — sonst
                    // wirkt die App hängengeblieben.
                    let ticker = Task { @MainActor [weak self] in
                        var seconds = 0
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            seconds += 1
                            guard !Task.isCancelled, self?.state == .processing else { return }
                            if seconds >= 3 { self?.overlay.setPhase(.processing("Optimiere… \(seconds) s")) }
                        }
                    }
                    // Der Eintrag entsteht vor dem Einfügen, damit eine
                    // verspätete Korrektur ihn noch ergänzen kann.
                    let entry = HistoryStore.shared.add(raw: raw, refined: raw,
                                                        refinerName: "…", languageCode: languageCode)
                    let (refined, refinerName) = await RefinerChain.current().refine(
                        raw, languageCode: languageCode,
                        onLateResult: { late, name in
                            Task { @MainActor in
                                HistoryStore.shared.addLateRefinement(late, refinerName: name, to: entry.id)
                            }
                        })
                    ticker.cancel()
                    guard !Task.isCancelled, self.state == .processing else { return }
                    NSLog("Refined via \(refinerName): \(refined.prefix(80))")
                    HistoryStore.shared.complete(refined, refinerName: refinerName, to: entry.id)
                    self.paster.onFailure = { [weak self] reason in
                        self?.overlay.flash(.error(reason), duration: 2.5)
                    }
                    self.paster.paste(refined)
                    self.overlay.flash(.success)
                case .assist(let context):
                    guard !Task.isCancelled, self.state == .processing else { return }
                    // The panel takes over from here — it shows its own progress.
                    self.overlay.hide()
                    AssistPanelController.shared.show(context: context,
                                                      instruction: raw,
                                                      generateImmediately: true)
                }
            } catch {
                NSLog("stopAndProcess failed: \(error)")
                self.overlay.flash(.error("Transkription fehlgeschlagen"), duration: 2.0)
            }
            if self.state == .processing { self.finishToIdle() }
        }
    }

    private func finishToIdle() {
        pipelineTask = nil
        mode = .dictation
        state = .idle
    }

    // MARK: - App Nap

    private func beginActivity() {
        endActivity()
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Diktat läuft"
        )
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
