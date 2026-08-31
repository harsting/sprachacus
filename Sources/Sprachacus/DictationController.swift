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
    private var activity: NSObjectProtocol?

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

    func cancel() {
        guard state == .recording else { return }
        recorder.stop()
        transcriber.cancel()
        endActivity()
        overlay.hide()
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
                try await transcriber.start(locale: locale) { _ in
                    // Live partials available here if we ever want a text preview.
                }
                guard self.state == .recording else {
                    transcriber.cancel()
                    return
                }
                try self.recorder.start(
                    onBuffer: { [weak transcriber] buffer in transcriber?.feed(buffer) },
                    onLevel: { [weak self] level in
                        Task { @MainActor in self?.overlay.model.pushLevel(level) }
                    }
                )
                self.beginActivity()
                self.overlay.show(phase: .recording)
            } catch {
                NSLog("startRecording failed: \(error)")
                self.recorder.stop()
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
        endActivity()
        let transcriber = self.transcriber
        let languageCode = Settings.shared.localeIdentifier

        Task { @MainActor in
            do {
                let raw = try await transcriber.finish()
                guard !raw.isEmpty else {
                    self.overlay.flash(.error("Nichts verstanden"), duration: 1.2)
                    self.finishToIdle()
                    return
                }
                switch mode {
                case .dictation:
                    self.overlay.setPhase(.processing("Optimiere…"))
                    let (refined, refinerName) = await RefinerChain.current().refine(raw, languageCode: languageCode)
                    NSLog("Refined via \(refinerName): \(refined.prefix(80))")
                    HistoryStore.shared.add(raw: raw, refined: refined,
                                            refinerName: refinerName, languageCode: languageCode)
                    self.paster.paste(refined)
                    self.overlay.flash(.success)
                case .assist(let context):
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
            self.finishToIdle()
        }
    }

    private func finishToIdle() {
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
