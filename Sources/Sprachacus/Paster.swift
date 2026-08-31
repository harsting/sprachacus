import AppKit

/// Puts the refined text on the pasteboard, synthesizes Cmd+V into the
/// frontmost app, then restores the previous pasteboard contents.
/// Requires the Accessibility permission for CGEvent posting.
final class Paster {
    private static let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V

    func paste(_ text: String) {
        let pasteboard = NSPasteboard.general

        let savedItems: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            var dict = [NSPasteboard.PasteboardType: Data]()
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        // Small grace period so the pasteboard write settles before Cmd+V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true)
            keyDown?.flags = .maskCommand
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)

            // Restore the previous pasteboard — but only if nothing else
            // wrote to it in the meantime. Slow apps (Electron) need the delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard pasteboard.changeCount == ourChangeCount, !savedItems.isEmpty else { return }
                pasteboard.clearContents()
                let items = savedItems.map { dict -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in dict { item.setData(data, forType: type) }
                    return item
                }
                pasteboard.writeObjects(items)
            }
        }
    }
}
