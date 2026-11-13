import AppKit
import AVFoundation
import FoundationModels
import SwiftUI

/// Begrüßung und Einrichtung beim ersten Start.
///
/// Vorher verteilte sich die Einrichtung auf ein Terminal-Skript, zwei
/// Systemdialoge und graue Punkte in den Einstellungen — wer die App nicht
/// selbst gebaut hat, sah nie, was noch fehlt. Dieses Fenster zeigt den
/// Zustand live und hat für jeden Punkt den passenden Knopf.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Sprachacus einrichten"
            win.isReleasedWhenClosed = false
            win.center()
            win.contentView = NSHostingView(rootView: SetupView())
            win.delegate = self
            window = win
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Einmal gesehen reicht — beim nächsten Start nicht wieder von selbst.
        Settings.shared.setupSeen = true
        if !MainWindowController.shared.isOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Beobachtet den Einrichtungsstand. Abgefragt statt beobachtet, weil es für
/// die Bedienungshilfen-Freigabe keine Benachrichtigung gibt.
@MainActor
final class SetupStatus: ObservableObject {
    @Published var accessibility = false
    @Published var microphone = false
    @Published var appleIntelligence = false
    @Published var claudeCLI: String?
    @Published var speechModelInstalled = false
    @Published var inputDevice: String?
    @Published var lidWarning = false
    @Published var dictationCount = 0
    @Published var modelDownload: Double?

    private var timer: Timer?
    private var startCount = 0

    /// Hat der Nutzer seit dem Öffnen dieses Fensters etwas diktiert?
    var triedDictation: Bool { dictationCount > startCount }

    var essentialsDone: Bool { accessibility && microphone }

    func start() {
        startCount = HistoryStore.shared.entries.count
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        accessibility = Permissions.accessibilityGranted
        microphone = Permissions.microphoneGranted
        if case .available = SystemLanguageModel.default.availability {
            appleIntelligence = true
        } else {
            appleIntelligence = false
        }
        claudeCLI = ClaudeCLI.resolvePath()
        dictationCount = HistoryStore.shared.entries.count

        let priority = Settings.shared.inputDevicePriority
        let connected = AudioDevices.inputs()
        let chosen = priority.compactMap { uid in connected.first { $0.uid == uid } }.first
            ?? AudioDevices.defaultInputID().flatMap { id in connected.first { $0.id == id } }
        inputDevice = chosen?.name
        lidWarning = AudioDevices.lidIsClosed() && (chosen.map { AudioDevices.isBuiltIn($0.id) } ?? false)

        Task { @MainActor in
            let locale = Locale(identifier: Settings.shared.localeIdentifier)
            speechModelInstalled = await Transcriber.isModelInstalled(locale: locale)
        }
    }

    func downloadSpeechModel() {
        guard modelDownload == nil else { return }
        modelDownload = 0
        Task { @MainActor in
            let locale = Locale(identifier: Settings.shared.localeIdentifier)
            try? await Transcriber.ensureModel(locale: locale) { [weak self] progress in
                Task { @MainActor in self?.modelDownload = progress }
            }
            modelDownload = nil
            refresh()
        }
    }
}

struct SetupView: View {
    @StateObject private var status = SetupStatus()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                SetupRow(done: status.accessibility,
                         title: "Bedienungshilfen",
                         detail: "Nötig für die Taste und fürs Einfügen. macOS verlangt, dass du Sprachacus in den Systemeinstellungen selbst anhakst — die App merkt es sofort, ein Neustart ist nicht nötig.",
                         actionTitle: status.accessibility ? nil : "Systemeinstellungen öffnen") {
                    Permissions.requestAccessibility()
                    Self.openSettings("Privacy_Accessibility")
                }

                SetupRow(done: status.microphone,
                         title: "Mikrofon",
                         detail: "Ohne Mikrofon gibt es nichts zu transkribieren.",
                         actionTitle: status.microphone ? nil : "Erlauben") {
                    Task {
                        let granted = await Permissions.requestMicrophone()
                        if !granted { Self.openSettings("Privacy_Microphone") }
                        status.refresh()
                    }
                }

                SetupRow(done: status.speechModelInstalled,
                         title: "Sprachmodell",
                         detail: status.speechModelInstalled
                            ? "Das Modell für \(Settings.shared.localeIdentifier) liegt auf dem Gerät."
                            : "macOS lädt es sonst beim ersten Diktat — das dauert dann mitten im Satz. Besser jetzt.",
                         actionTitle: status.speechModelInstalled || status.modelDownload != nil ? nil : "Jetzt laden") {
                    status.downloadSpeechModel()
                }
                if let progress = status.modelDownload {
                    ProgressView(value: progress)
                        .padding(.leading, 30)
                }

                SetupRow(done: status.inputDevice != nil && !status.lidWarning,
                         title: "Mikrofon-Auswahl",
                         detail: eingangText,
                         actionTitle: "Einstellungen öffnen") {
                    MainWindowController.shared.show(tab: .settings)
                }

                SetupRow(done: status.appleIntelligence || status.claudeCLI != nil,
                         title: "KI-Korrektur",
                         detail: korrekturText,
                         actionTitle: status.appleIntelligence ? nil : "Apple Intelligence öffnen") {
                    Self.openSettings(nil, pane: "com.apple.Siri-Settings.extension")
                }
                if status.claudeCLI == nil {
                    CommandHint(command: "npm install -g @anthropic-ai/claude-code")
                        .padding(.leading, 30)
                }

                SetupRow(done: status.triedDictation,
                         title: "Probe",
                         detail: status.triedDictation
                            ? "Läuft. Der Text steht im Verlauf."
                            : "Klick in ein Textfeld, drück die rechte ⌥-Taste, sag einen Satz, drück sie erneut.",
                         actionTitle: nil, action: nil)

                Divider()
                footer
            }
            .padding(24)
        }
        .frame(minWidth: 620, minHeight: 560)
        .onAppear { status.start() }
        .onDisappear { status.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Willkommen bei Sprachacus")
                .font(.title2.bold())
            Text("Diktieren mit der rechten Optionstaste — alles Gesprochene bleibt auf diesem Mac. Die ersten beiden Punkte sind Pflicht, der Rest macht es besser.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var eingangText: String {
        if status.lidWarning {
            return "Zurzeit das eingebaute Mikrofon — bei geschlossenem Deckel liefert das keinen Ton. Stell in den Einstellungen ein angeschlossenes Mikrofon nach oben."
        }
        if let device = status.inputDevice {
            return "Aufgenommen wird über „\(device)“. In den Einstellungen lässt sich eine Reihenfolge festlegen: Kopfhörer zuerst, sonst das Tischmikrofon."
        }
        return "Kein Eingabegerät gefunden."
    }

    private var korrekturText: String {
        switch (status.appleIntelligence, status.claudeCLI) {
        case (true, let cli?):
            return "Apple Intelligence ist aktiv (lokal, schnell). Die Claude CLI liegt unter \(cli) und übernimmt Assist und Meeting-Zusammenfassungen."
        case (true, nil):
            return "Apple Intelligence ist aktiv — das reicht fürs Diktat. Für Assist und Meeting-Zusammenfassungen braucht es zusätzlich die Claude CLI."
        case (false, let cli?):
            return "Apple Intelligence ist nicht aktiv; die Korrektur läuft über die Claude CLI (\(cli)). Das ist langsamer, aber gut."
        case (false, nil):
            return "Weder Apple Intelligence noch die Claude CLI gefunden. Ohne beides wird der Rohtext eingefügt — brauchbar, aber ohne Komma und Großschreibung. Die CLI nutzt übrigens dein bestehendes Abo; Sprachacus bekommt keine Zugangsdaten zu sehen."
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(status.essentialsDone
                     ? "Fertig — die Pflichtpunkte stehen."
                     : "Die ersten beiden Punkte sind Pflicht, der Rest ist Komfort.")
                    .font(.callout.weight(.medium))
                Text("Dieses Fenster kommt über das Mikrofon-Symbol → „Einrichtung…“ jederzeit zurück.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(status.essentialsDone ? "Fertig" : "Später") {
                Settings.shared.setupSeen = true
                SetupWindowController.shared.close()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private static func openSettings(_ privacySection: String?, pane: String = "com.apple.preference.security") {
        let url: URL?
        if let privacySection {
            url = URL(string: "x-apple.systempreferences:\(pane)?\(privacySection)")
        } else {
            url = URL(string: "x-apple.systempreferences:\(pane)")
        }
        if let url { NSWorkspace.shared.open(url) }
    }
}

private struct SetupRow: View {
    let done: Bool
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
                .font(.title3)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
    }
}

private struct CommandHint: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
            Button(copied ? "Kopiert" : "Kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .controlSize(.small)
        }
    }
}
