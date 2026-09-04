import AppKit
import SwiftUI

/// Compact floating window shown while a meeting is being recorded. It is a
/// non-activating panel so it can sit above a full-screen video call without
/// taking focus away from it.
@MainActor
final class MeetingWindowController: NSObject, NSWindowDelegate {
    static let shared = MeetingWindowController()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = "Meeting-Aufzeichnung"
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.minSize = NSSize(width: 360, height: 240)
            panel.delegate = self
            panel.contentView = NSHostingView(
                rootView: MeetingLiveView().environmentObject(MeetingController.shared)
            )
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: frame.maxX - 440, y: frame.maxY - 360))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Closing the window only hides it — the meeting keeps recording until
    /// the user explicitly ends it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

struct MeetingLiveView: View {
    @EnvironmentObject private var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.isRecording ? Color.red : Color.secondary)
                    .frame(width: 9, height: 9)
                Text(MeetingStore.durationText(controller.elapsed))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                if controller.isSummarizing {
                    ProgressView().controlSize(.small)
                }
            }

            HStack(spacing: 14) {
                LevelIndicator(label: "Ich", level: controller.micLevel, color: .blue, active: true)
                LevelIndicator(label: "Andere", level: controller.systemLevel, color: .green,
                               active: controller.systemAudioActive)
            }

            if controller.echoRisk {
                Label("Ton läuft über die Lautsprecher — das Mikrofon hört die Gegenseite mit. Kopfhörer aufsetzen oder Echo-Unterdrückung einschalten.",
                      systemImage: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let status = controller.statusMessage {
                Label(status, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(controller.segments) { segment in
                            SegmentRow(source: segment.source, text: segment.text, isPartial: false)
                                .id(segment.id)
                        }
                        if !controller.partialMe.isEmpty {
                            SegmentRow(source: .me, text: controller.partialMe, isPartial: true)
                                .id("partialMe")
                        }
                        if !controller.partialOthers.isEmpty {
                            SegmentRow(source: .others, text: controller.partialOthers, isPartial: true)
                                .id("partialOthers")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .onChange(of: controller.segments.count) { _, _ in
                    if let last = controller.segments.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .overlay {
                    if controller.segments.isEmpty && controller.partialMe.isEmpty && controller.partialOthers.isEmpty {
                        Text("Warte auf Sprache…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Button {
                MeetingController.shared.stopAndSummarize()
            } label: {
                Label("Beenden & Zusammenfassen", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!controller.isRecording)
        }
        .padding(14)
        .frame(minWidth: 360, minHeight: 240)
    }
}

private struct SegmentRow: View {
    let source: MeetingSegment.Source
    let text: String
    let isPartial: Bool

    private var color: Color { source == .me ? .blue : .green }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(source.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 44, alignment: .leading)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(isPartial ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LevelIndicator: View {
    let label: String
    let level: Float
    let color: Color
    let active: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(active ? color : Color.secondary)
                        .frame(width: geo.size.width * CGFloat(min(1, max(0.02, level * 16))))
                        .animation(.easeOut(duration: 0.12), value: level)
                }
            }
            .frame(height: 5)
            if !active {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("System-Audio ist nicht aktiv")
            }
        }
    }
}
