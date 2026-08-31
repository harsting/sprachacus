import AppKit
import SwiftUI

/// Non-activating panel at the bottom-center of the screen. It must never
/// become key — the target app keeps keyboard focus the whole time.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        return panel
    }

    func show(phase: OverlayModel.Phase) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        if panel == nil { panel = makePanel() }
        guard let panel else { return }

        model.phase = phase
        if case .recording = phase { model.resetLevels() }

        // Recompute position on every show — displays/Spaces may have changed.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.midX - panel.frame.width / 2
            let y = frame.minY + 24
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func setPhase(_ phase: OverlayModel.Phase) {
        model.phase = phase
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
        model.phase = .hidden
    }

    /// Show a terminal phase (checkmark/error) briefly, then hide.
    func flash(_ phase: OverlayModel.Phase, duration: TimeInterval = 0.9) {
        show(phase: phase)
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }
}
