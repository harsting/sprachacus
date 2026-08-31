import AppKit

/// Global right-Option tap detection plus Escape-to-cancel.
/// Requires the Accessibility permission (same one the Paster needs).
///
/// The toggle fires on key-UP and only if no other key was pressed while
/// right-Option was held, so using ⌥ as a modifier never triggers dictation.
final class HotkeyMonitor {
    var onToggle: (() -> Void)?
    var onCancel: (() -> Void)?
    var isRecordingProvider: () -> Bool = { false }

    private static let rightOptionKeyCode: UInt16 = 61
    private static let escapeKeyCode: UInt16 = 53

    private var rightOptionDown = false
    private var usedAsModifier = false
    private var lastToggle = Date.distantPast
    private var monitors: [Any] = []

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        stop()
        // Global monitors never see events targeted at our own app, so add
        // local monitors too — the hotkey should also work while e.g. the
        // settings window has focus.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlagsChanged(event)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleKeyDown(event)
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == Self.rightOptionKeyCode else {
            // A different modifier went down while right-Option is held → combo, not a tap.
            if rightOptionDown { usedAsModifier = true }
            return
        }
        if event.modifierFlags.contains(.option) {
            rightOptionDown = true
            usedAsModifier = false
        } else if rightOptionDown {
            rightOptionDown = false
            let now = Date()
            // Only guards against duplicate event delivery — must stay well
            // below a human double-tap so the assist gesture (⌥⌥) gets through.
            if !usedAsModifier, now.timeIntervalSince(lastToggle) > 0.08 {
                lastToggle = now
                DispatchQueue.main.async { self.onToggle?() }
            }
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        if rightOptionDown { usedAsModifier = true }
        if event.keyCode == Self.escapeKeyCode, isRecordingProvider() {
            DispatchQueue.main.async { self.onCancel?() }
        }
    }
}
