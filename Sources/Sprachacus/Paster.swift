import AppKit
import ApplicationServices

/// Legt den Text in die Zwischenablage, schickt Cmd+V an die vorderste App
/// und stellt die vorherige Zwischenablage wieder her.
/// Braucht die Bedienungshilfen-Freigabe für das Senden von Tastendrücken.
final class Paster {
    private static let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V

    /// So lange wird höchstens darauf gewartet, dass die Ziel-App den Text
    /// übernommen hat, bevor die alte Zwischenablage zurückkommt.
    private static let confirmationBudget: TimeInterval = 3.0

    /// Meldet, dass der Text nicht eingefügt werden konnte. Der Text liegt
    /// dann in der Zwischenablage und im Verlauf.
    var onFailure: ((String) -> Void)?

    func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedItems = Self.snapshot(of: pasteboard)

        // Schreiben und **nachlesen**. Ohne diese Prüfung konnte Cmd+V den
        // vorherigen Inhalt einfügen: Hält eine andere App die Zwischenablage
        // gerade, schlägt das Schreiben fehl — `setString` meldet das zwar,
        // es wurde aber nie ausgewertet. Danach stand noch der alte Text
        // drin, und genau der landete im Dokument.
        guard Self.write(text, to: pasteboard) else {
            onFailure?("Zwischenablage ist blockiert — Text steht im Verlauf")
            return
        }
        let ourChangeCount = pasteboard.changeCount
        let before = Self.focusedTextSignature()

        // Kurze Atempause, damit die Ziel-App den neuen Inhalt sieht.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Self.sendPasteShortcut()
            Self.restoreWhenPasteLanded(pasteboard: pasteboard,
                                        expectedChangeCount: ourChangeCount,
                                        signatureBefore: before,
                                        savedItems: savedItems)
        }
    }

    // MARK: - Zwischenablage

    private static func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        pasteboard.pasteboardItems?.map { item in
            var dict = [NSPasteboard.PasteboardType: Data]()
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        } ?? []
    }

    /// Schreibt und prüft durch Nachlesen. Mehrere Versuche, weil eine andere
    /// App die Zwischenablage kurz belegt halten kann.
    private static func write(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        for attempt in 0..<5 {
            pasteboard.clearContents()
            if pasteboard.setString(text, forType: .string),
               pasteboard.string(forType: .string) == text {
                return true
            }
            NSLog("Paster: Zwischenablage ließ sich nicht beschreiben (Versuch \(attempt + 1))")
            Thread.sleep(forTimeInterval: 0.03)
        }
        return false
    }

    private static func sendPasteShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Stellt die alte Zwischenablage erst wieder her, wenn der Text
    /// tatsächlich angekommen ist.
    ///
    /// Vorher wurde nach festen 0,6 s zurückgestellt. War die Ziel-App
    /// langsamer, las sie die Zwischenablage erst danach — und fügte den
    /// *alten* Inhalt ein. Deshalb wird jetzt am Eingabefeld nachgesehen, ob
    /// sich etwas getan hat, und nur dann zurückgestellt.
    private static func restoreWhenPasteLanded(pasteboard: NSPasteboard,
                                               expectedChangeCount: Int,
                                               signatureBefore: String?,
                                               savedItems: [[NSPasteboard.PasteboardType: Data]]) {
        guard !savedItems.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            // Ohne lesbares Eingabefeld — manche Apps geben nichts preis —
            // wartet die Schleife die volle Zeit ab. Großzügig zu warten ist
            // harmlos; zu früh zurückzustellen war der Fehler.
            let deadline = Date().addingTimeInterval(confirmationBudget)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                if let before = signatureBefore, let now = focusedTextSignature(), now != before { break }
            }
            DispatchQueue.main.async {
                guard pasteboard.changeCount == expectedChangeCount else { return }
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

    // MARK: - Bedienungshilfen

    /// Kennzeichen des Textes im gerade fokussierten Eingabefeld.
    ///
    /// Bewusst nur die Zeichenzahl, wo es geht: Den gesamten Text eines
    /// Dokuments zu lesen wäre teuer, und nötig ist nur die Information
    /// „hat sich etwas geändert".
    private static func focusedTextSignature() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)

        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let number = count as? Int {
            return "n:\(number)"
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let string = value as? String {
            return "v:\(string.count)"
        }
        return nil
    }
}
