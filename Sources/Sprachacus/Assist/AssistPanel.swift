import AppKit
import SwiftUI

@MainActor
final class AssistModel: ObservableObject {
    @Published var context = ""
    @Published var instruction = ""
    @Published var result = ""
    @Published var isGenerating = false
    @Published var providerName: String?
    @Published var errorMessage: String?

    var languageCode: String { Settings.shared.localeIdentifier }

    func generate() {
        let instruction = self.instruction
        guard !instruction.trimmingCharacters(in: .whitespaces).isEmpty, !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        providerName = nil
        let context = self.context
        let languageCode = self.languageCode

        Task { @MainActor in
            do {
                let output = try await AssistComposer.compose(context: context.isEmpty ? nil : context,
                                                              instruction: instruction,
                                                              languageCode: languageCode)
                self.result = output.text
                self.providerName = output.providerName
                HistoryStore.shared.add(raw: instruction, refined: output.text,
                                        refinerName: output.providerName,
                                        languageCode: languageCode, kind: .assist)
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isGenerating = false
        }
    }
}

/// Window for the assist mode. Unlike the dictation overlay this one activates
/// (the user edits text in it) and returns focus to the previous app on insert.
@MainActor
final class AssistPanelController: NSObject, NSWindowDelegate {
    static let shared = AssistPanelController()

    let model = AssistModel()
    private var window: NSWindow?
    private let paster = Paster()

    /// - Parameter generateImmediately: true for the voice flow (instruction is
    ///   already dictated), false when opened empty from the menu.
    func show(context: String?, instruction: String, generateImmediately: Bool) {
        model.context = context?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        model.instruction = instruction
        model.result = ""
        model.providerName = nil
        model.errorMessage = nil

        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Sprachacus Assist"
            win.isReleasedWhenClosed = false
            win.minSize = NSSize(width: 480, height: 420)
            win.center()
            win.delegate = self
            win.contentView = NSHostingView(rootView: AssistView(model: model))
            window = win
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()

        if generateImmediately { model.generate() }
    }

    /// Hides the app so the previously focused app comes back, then pastes.
    func insert(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)
        // Give the frontmost app a moment to regain focus before ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [paster] in
            paster.paste(text)
        }
    }

    func close() {
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    /// The assist window is a tool window — closing it must never quit the app.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct AssistView: View {
    @ObservedObject var model: AssistModel
    @State private var showContext = false

    private var hasContext: Bool { !model.context.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            contextSection

            VStack(alignment: .leading, spacing: 4) {
                Text("Anweisung")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.instruction)
                    .font(.system(size: 12))
                    .frame(height: 58)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Ergebnis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let provider = model.providerName {
                        RefinerBadge(name: provider)
                    }
                    Spacer()
                    if model.isGenerating {
                        ProgressView().controlSize(.small)
                    }
                }
                TextEditor(text: $model.result)
                    .font(.system(size: 13))
                    .frame(maxHeight: .infinity)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if model.result.isEmpty && !model.isGenerating {
                            Text(model.errorMessage == nil
                                 ? "Noch kein Text — „Generieren“ drücken."
                                 : "")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            HStack {
                Button("Verwerfen") { AssistPanelController.shared.close() }
                Spacer()
                Button(model.result.isEmpty ? "Generieren" : "Neu generieren") { model.generate() }
                    .disabled(model.isGenerating || model.instruction.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Kopieren") { copyToPasteboard(model.result) }
                    .disabled(model.result.isEmpty)
                Button("Einfügen") { AssistPanelController.shared.insert(model.result) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.result.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 420)
    }

    @ViewBuilder
    private var contextSection: some View {
        if hasContext {
            DisclosureGroup(isExpanded: $showContext) {
                ScrollView {
                    Text(model.context)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            } label: {
                Label("Kontext aus der Zwischenablage · \(model.context.count) Zeichen",
                      systemImage: "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Label("Kein Kontext in der Zwischenablage — der Text wird allein aus der Anweisung verfasst.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
