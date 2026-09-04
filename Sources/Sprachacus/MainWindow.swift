import AppKit
import SwiftUI

/// The "Verlauf & Einstellungen" window — history of dictations plus
/// refiner configuration including an editable correction prompt.
enum MainTab: Hashable {
    case history
    case meetings
    case settings
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = MainWindowController()
    @Published var selectedTab: MainTab = .history
    private var window: NSWindow?

    func show(tab: MainTab? = nil) {
        if let tab { selectedTab = tab }
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Sprachacus"
            win.isReleasedWhenClosed = false
            win.minSize = NSSize(width: 560, height: 400)
            win.center()
            win.contentView = NSHostingView(
                rootView: MainView()
                    .environmentObject(HistoryStore.shared)
                    .environmentObject(MeetingStore.shared)
                    .environmentObject(MeetingController.shared)
            )
            win.delegate = self
            window = win
        }
        // Show a Dock icon while the window is open — as a bare .accessory
        // app the window would not reliably come to the front (and the user
        // couldn't Cmd-Tab back to it).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        // Back to menu-bar-only once the window closes.
        NSApp.setActivationPolicy(.accessory)
    }

    /// Closing the window either keeps the app alive in the menu bar
    /// (dictation stays armed) or quits it completely — the user decides,
    /// once or permanently.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch Settings.shared.windowCloseAction {
        case .background:
            return true
        case .quit:
            NSApp.terminate(nil)
            return true
        case .ask:
            let alert = NSAlert()
            alert.messageText = "Sprachacus komplett beenden?"
            alert.informativeText = """
            „Im Hintergrund weiterlaufen“: Das Fenster schließt, aber das Diktat \
            mit der rechten ⌥-Taste bleibt aktiv — erreichbar über das \
            Mikrofon-Symbol in der Menüleiste.

            „Komplett beenden“: Die App stoppt vollständig, auch der Hotkey.
            """
            alert.addButton(withTitle: "Im Hintergrund weiterlaufen")
            alert.addButton(withTitle: "Komplett beenden")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Entscheidung merken"
            let response = alert.runModal()
            let quit = response == .alertSecondButtonReturn
            if alert.suppressionButton?.state == .on {
                Settings.shared.windowCloseAction = quit ? .quit : .background
            }
            if quit { NSApp.terminate(nil) }
            return true
        }
    }
}

struct MainView: View {
    @ObservedObject private var controller = MainWindowController.shared

    var body: some View {
        TabView(selection: $controller.selectedTab) {
            HistoryTab()
                .tabItem { Label("Verlauf", systemImage: "clock.arrow.circlepath") }
                .tag(MainTab.history)
            MeetingsTab()
                .tabItem { Label("Meetings", systemImage: "person.wave.2") }
                .tag(MainTab.meetings)
            SettingsTab()
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .frame(minWidth: 560, minHeight: 400)
    }
}

// MARK: - History

struct HistoryTab: View {
    @EnvironmentObject private var store: HistoryStore

    var body: some View {
        VStack(spacing: 0) {
            if store.entries.isEmpty {
                ContentUnavailableView(
                    "Noch keine Diktate",
                    systemImage: "mic",
                    description: Text("Drücke die rechte ⌥-Taste, sprich, und drücke sie erneut — dein Diktat erscheint hier.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.entries) { entry in
                        HistoryRow(entry: entry)
                    }
                }
            }
            Divider()
            HStack {
                Text("\(store.entries.count) Einträge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Verlauf löschen", role: .destructive) { store.clear() }
                    .disabled(store.entries.isEmpty)
            }
            .padding(10)
        }
    }
}

struct HistoryRow: View {
    @EnvironmentObject private var store: HistoryStore
    let entry: HistoryEntry
    @State private var isReRefining = false

    private var isAssist: Bool { entry.kind == .assist }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                TextBlock(label: isAssist ? "Anweisung" : "Roh-Transkript", text: entry.raw)
                TextBlock(label: (isAssist ? "Ergebnis · " : "Optimiert · ") + entry.refinerName,
                          text: entry.refined)
                HStack {
                    Button(isAssist ? "Ergebnis kopieren" : "Optimiert kopieren") {
                        copyToPasteboard(entry.refined)
                    }
                    Button(isAssist ? "Anweisung kopieren" : "Roh kopieren") {
                        copyToPasteboard(entry.raw)
                    }
                    if !isAssist {
                        Button {
                            reRefine()
                        } label: {
                            if isReRefining {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Neu optimieren")
                            }
                        }
                        .disabled(isReRefining)
                        .help("Optimiert das Roh-Transkript erneut mit den aktuellen Einstellungen — praktisch zum Testen von Prompt-Änderungen.")
                    }
                }
                .controlSize(.small)
            }
            .padding(.vertical, 6)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.refined)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(entry.date, format: .dateTime.day().month().year().hour().minute())
                        if isAssist { KindBadge() }
                        RefinerBadge(name: entry.refinerName)
                        Text(entry.languageCode)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reRefine() {
        isReRefining = true
        Task { @MainActor in
            let (refined, refinerName) = await RefinerChain.current()
                .refine(entry.raw, languageCode: entry.languageCode)
            var updated = entry
            updated.refined = refined
            updated.refinerName = refinerName
            store.update(updated)
            isReRefining = false
        }
    }
}

struct RefinerBadge: View {
    let name: String

    private var color: Color {
        switch name {
        case "Apple Intelligence": return .purple
        case "Claude CLI": return .orange
        default: return .gray
        }
    }

    var body: some View {
        Text(name)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct KindBadge: View {
    var body: some View {
        Text("Assist")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.blue.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.blue)
    }
}

struct TextBlock: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

@MainActor
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Settings

struct SettingsTab: View {
    @AppStorage("refiner") private var refinerRaw = RefinerChoice.auto.rawValue
    @AppStorage("locale") private var localeIdentifier = "de-DE"
    @AppStorage("windowCloseAction") private var windowCloseRaw = WindowCloseAction.ask.rawValue
    @AppStorage("customPrompt.de") private var customPromptDe = ""
    @AppStorage("customPrompt.en") private var customPromptEn = ""
    @AppStorage("assistPrompt.de") private var assistPromptDe = ""
    @AppStorage("assistPrompt.en") private var assistPromptEn = ""
    @AppStorage("assistProvider") private var assistProviderRaw = AssistProviderChoice.auto.rawValue
    @AppStorage("userName") private var userName = ""
    @AppStorage("inputDeviceUID") private var inputDeviceUID = ""
    @AppStorage("meetingEchoCancellation") private var meetingEchoCancellation = true
    @State private var inputDevices: [AudioDevices.Device] = []

    @State private var fmAvailable: Bool?
    @State private var claudePath: String?
    @State private var testInput = ""
    @State private var testOutput: String?
    @State private var testRefinerName: String?
    @State private var isTesting = false

    private var isGerman: Bool { localeIdentifier.hasPrefix("de") }

    var body: some View {
        Form {
            Section {
                TextField("Dein Name", text: $userName, prompt: Text("z. B. Alex Meier"))
            } header: {
                Text("Persönliches")
            } footer: {
                Text("Assist verfasst Texte in deinem Namen, und in Meeting-Zusammenfassungen wird „Ich“ dir zugeordnet. Das Feld darf leer bleiben — dann arbeitet die KI ohne Namen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Eingang", selection: $inputDeviceUID) {
                    Text("Systemstandard").tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                if !inputDeviceUID.isEmpty, !inputDevices.contains(where: { $0.uid == inputDeviceUID }) {
                    Label("Das gewählte Mikrofon ist gerade nicht angeschlossen — Sprachacus nutzt so lange den Systemstandard.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("Echo-Unterdrückung in Meetings", isOn: $meetingEchoCancellation)
                HStack {
                    Spacer()
                    Button("Geräte neu einlesen") { inputDevices = AudioDevices.inputs() }
                        .controlSize(.small)
                }
            } header: {
                Text("Mikrofon")
            } footer: {
                Text("Legt fest, worüber deine eigene Stimme aufgenommen wird — für Diktat und für den „Ich“-Kanal in Meetings. Die Echo-Unterdrückung verhindert, dass die Gegenseite über die Lautsprecher ins Mikrofon zurückläuft und doppelt im Transkript landet; sie gilt nur für Meetings, nicht fürs Diktat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Methode", selection: $refinerRaw) {
                    ForEach(RefinerChoice.allCases, id: \.rawValue) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                LabeledContent("Apple Intelligence") {
                    AvailabilityDot(available: fmAvailable,
                                    availableText: "verfügbar",
                                    unavailableText: "nicht aktiviert")
                }
                LabeledContent("Claude CLI") {
                    AvailabilityDot(available: claudePath.map { _ in true },
                                    availableText: claudePath ?? "",
                                    unavailableText: "nicht gefunden")
                }

                if fmAvailable == false {
                    SetupHint(text: "Apple Intelligence einschalten: Systemeinstellungen → Apple Intelligence & Siri. Nach dem Aktivieren lädt macOS das Modell im Hintergrund.",
                              command: nil)
                }
                if claudePath == nil {
                    SetupHint(text: "Claude CLI installieren, danach im Terminal einmal „claude“ starten und anmelden (Abo oder API-Guthaben):",
                              command: "npm install -g @anthropic-ai/claude-code")
                }

                HStack {
                    Spacer()
                    Button("Erneut prüfen") { checkAvailability() }
                        .controlSize(.small)
                }
            } header: {
                Text("KI-Optimierung")
            } footer: {
                Text("Sprachacus speichert selbst keine Zugangsdaten — es nutzt die Anmeldung der Claude CLI bzw. das lokale Apple-Modell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sprache") {
                Picker("Diktatsprache", selection: $localeIdentifier) {
                    Text("Deutsch").tag("de-DE")
                    Text("Englisch").tag("en-US")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section {
                Picker("Beim Schließen des Fensters", selection: $windowCloseRaw) {
                    ForEach(WindowCloseAction.allCases, id: \.rawValue) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
            } footer: {
                Text("„Im Hintergrund weiterlaufen“ hält das Diktat (rechte ⌥) aktiv — die App bleibt als Mikrofon-Symbol in der Menüleiste. „App komplett beenden“ stoppt auch den Hotkey.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                PromptEditor(stored: isGerman ? $customPromptDe : $customPromptEn,
                             defaultPrompt: RefinerPrompts.defaultInstructions(languageCode: localeIdentifier))
            } header: {
                Text("Korrektur-Anweisung (\(isGerman ? "Deutsch" : "Englisch"))")
            } footer: {
                Text("Diese Anweisung erhält die KI zusammen mit deinem Roh-Transkript. Änderungen gelten sofort — teste sie unten oder im Verlauf mit „Neu optimieren“. Zusätzlich hängt Sprachacus immer eine feste Schutzregel an, damit die KI dein Diktat nur korrigiert und nie beantwortet (z. B. keine E-Mail schreibt, wenn du einen E-Mail-Wunsch diktierst).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Verfasst mit", selection: $assistProviderRaw) {
                    ForEach(AssistProviderChoice.allCases, id: \.rawValue) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } header: {
                Text("Assist-Modus")
            } footer: {
                Text("Rechte ⌥ doppelt tippen: Die Zwischenablage wird Kontext, deine gesprochene Anweisung sagt, was daraus werden soll. Empfehlung Claude CLI — das lokale Apple-Modell hat im Test Anweisungen befolgt, die im kopierten Fremdtext standen (z. B. „ignoriere alle vorherigen Anweisungen“ in einer E-Mail), und formuliert schwächer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                PromptEditor(stored: isGerman ? $assistPromptDe : $assistPromptEn,
                             defaultPrompt: AssistPrompts.defaultInstructions(languageCode: localeIdentifier))
            } header: {
                Text("Assist-Anweisung (\(isGerman ? "Deutsch" : "Englisch"))")
            } footer: {
                Text("Diese Anweisung bestimmt Stil und Form der verfassten Texte. Sprachacus hängt immer eine feste Schutzregel an, die den kopierten Text als reines Zitat markiert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Test") {
                TextField("Roh-Transkript zum Testen", text: $testInput, axis: .vertical)
                    .lineLimit(2...4)
                HStack {
                    Button {
                        runTest()
                    } label: {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Optimierung testen")
                        }
                    }
                    .disabled(isTesting || testInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let name = testRefinerName {
                        RefinerBadge(name: name)
                    }
                }
                if let output = testOutput {
                    TextBlock(label: "Ergebnis", text: output)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            inputDevices = AudioDevices.inputs()
            checkAvailability()
            if testInput.isEmpty {
                testInput = isGerman
                    ? "ähm also ich wollte halt sagen dass wir uns ähm morgen um zehn uhr treffen sollten glaube ich"
                    : "um so I wanted to like say that we should uh meet tomorrow at ten I think"
            }
        }
    }

    private func checkAvailability() {
        Task { @MainActor in
            fmAvailable = await FoundationModelsRefiner().isAvailable()
            claudePath = ClaudeCLIRefiner.resolveClaudePath()
        }
    }

    private func runTest() {
        isTesting = true
        testOutput = nil
        testRefinerName = nil
        Task { @MainActor in
            let (output, name) = await RefinerChain.current().refine(testInput, languageCode: localeIdentifier)
            testOutput = output
            testRefinerName = name
            isTesting = false
        }
    }
}

/// Editor for one prompt. It always shows the EFFECTIVE prompt; storing the
/// default (or nothing) counts as "not customized".
struct PromptEditor: View {
    @Binding var stored: String
    let defaultPrompt: String

    private var isCustomized: Bool { !stored.isEmpty }

    private var binding: Binding<String> {
        Binding(
            get: { stored.isEmpty ? defaultPrompt : stored },
            set: { newValue in
                stored = (newValue == defaultPrompt
                          || newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ? "" : newValue
            }
        )
    }

    var body: some View {
        TextEditor(text: binding)
            .font(.system(size: 12))
            .frame(minHeight: 130)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        HStack {
            Button("Auf Standard zurücksetzen") { stored = "" }
                .disabled(!isCustomized)
            Spacer()
            Text(isCustomized ? "Angepasst" : "Standard")
                .font(.caption)
                .foregroundStyle(isCustomized ? Color.orange : Color.secondary)
        }
    }
}

/// Kurzer Einrichtungshinweis samt kopierbarem Befehl.
struct SetupHint: View {
    let text: String
    let command: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
            if let command {
                HStack(spacing: 6) {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                    Button("Kopieren") { copyToPasteboard(command) }
                        .controlSize(.mini)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AvailabilityDot: View {
    let available: Bool?
    let availableText: String
    let unavailableText: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(available == nil ? Color.gray : (available! ? Color.green : Color.red))
                .frame(width: 8, height: 8)
            Text(available == nil ? "prüfe…" : (available! ? availableText : unavailableText))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
