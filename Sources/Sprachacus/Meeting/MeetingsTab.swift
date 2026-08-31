import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingsTab: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var controller: MeetingController
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if store.meetings.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Meetings", systemImage: "person.wave.2")
                } description: {
                    Text("Starte eine Aufzeichnung über das Menüleisten-Symbol. Sprachacus transkribiert dein Mikrofon und den System-Ton getrennt und fasst danach zusammen.")
                } actions: {
                    Button("Meeting aufzeichnen") { controller.start() }
                        .disabled(controller.isRecording)
                }
                .frame(maxHeight: .infinity)
            } else {
                NavigationSplitView {
                    List(store.meetings, selection: $selection) { meeting in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.title)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(meeting.date, format: .dateTime.day().month().hour().minute())
                                Text(MeetingStore.durationText(meeting.duration))
                                if meeting.summary == nil {
                                    Text("ohne Zusammenfassung")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .tag(meeting.id)
                    }
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                } detail: {
                    if let id = selection, let meeting = store.meetings.first(where: { $0.id == id }) {
                        MeetingDetailView(meeting: meeting)
                            .id(meeting.id)
                    } else {
                        Text("Meeting auswählen")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            HStack {
                Text("\(store.meetings.count) Meetings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if controller.isRecording {
                    Button("Aufzeichnung beenden") { controller.stopAndSummarize() }
                } else {
                    Button("Meeting aufzeichnen") { controller.start() }
                }
            }
            .padding(10)
        }
        .onAppear {
            if selection == nil { selection = store.meetings.first?.id }
        }
    }
}

struct MeetingDetailView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var controller: MeetingController
    let meeting: MeetingMeta

    @State private var title: String = ""
    @State private var isSummarizing = false
    @State private var showDeleteConfirm = false

    private var segments: [MeetingSegment] { store.segments(for: meeting.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Titel", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .onSubmit(saveTitle)

                Text("\(MeetingStore.dateFormatter.string(from: meeting.date)) · \(MeetingStore.durationText(meeting.duration)) · \(segments.count) Abschnitte")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Zusammenfassung kopieren") { copyToPasteboard(meeting.summary ?? "") }
                        .disabled(meeting.summary == nil)
                    Button("Transkript kopieren") { copyToPasteboard(store.transcriptText(for: meeting.id)) }
                    Button("Als Markdown exportieren…") { export() }
                    Button {
                        resummarize()
                    } label: {
                        if isSummarizing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(meeting.summary == nil ? "Zusammenfassen" : "Neu zusammenfassen")
                        }
                    }
                    .disabled(isSummarizing)
                    Spacer()
                    Button("Löschen", role: .destructive) { showDeleteConfirm = true }
                }
                .controlSize(.small)

                if let summary = meeting.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Zusammenfassung")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let name = meeting.summarizerName {
                                RefinerBadge(name: name)
                            }
                        }
                        Text(summary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    Label("Noch keine Zusammenfassung — das Transkript ist gespeichert.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Transkript")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if segments.isEmpty {
                        Text("Kein Transkript vorhanden.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(segments) { segment in
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Text(segment.source.label)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(segment.source == .me ? Color.blue : Color.green)
                                        .frame(width: 46, alignment: .leading)
                                    Text(segment.text)
                                        .font(.system(size: 12))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(16)
        }
        .onAppear { title = meeting.title }
        .confirmationDialog("Meeting wirklich löschen?", isPresented: $showDeleteConfirm) {
            Button("Löschen", role: .destructive) { store.delete(meeting.id) }
        } message: {
            Text("„\(meeting.title)“ wird mit Transkript und Zusammenfassung dauerhaft entfernt.")
        }
    }

    private func saveTitle() {
        var updated = meeting
        updated.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? meeting.title : title
        store.update(updated)
    }

    private func resummarize() {
        isSummarizing = true
        Task { @MainActor in
            await controller.resummarize(meeting)
            isSummarizing = false
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = meeting.title
            .replacingOccurrences(of: "/", with: "-")
            .appending(".md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.markdown(for: meeting).write(to: url, atomically: true, encoding: .utf8)
    }
}
