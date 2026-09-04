import Foundation

enum RefinerChoice: String, CaseIterable {
    case auto
    case appleIntelligence
    case claudeCLI
    case off

    var title: String {
        switch self {
        case .auto: return "Automatisch (Apple Intelligence → Claude)"
        case .appleIntelligence: return "Apple Intelligence (lokal)"
        case .claudeCLI: return "Claude CLI (Haiku)"
        case .off: return "Aus (Rohtext einfügen)"
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    var refiner: RefinerChoice {
        get { RefinerChoice(rawValue: defaults.string(forKey: "refiner") ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "refiner") }
    }

    var localeIdentifier: String {
        get { defaults.string(forKey: "locale") ?? "de-DE" }
        set { defaults.set(newValue, forKey: "locale") }
    }

    var claudePath: String? {
        get { defaults.string(forKey: "claudePath") }
        set { defaults.set(newValue, forKey: "claudePath") }
    }

    /// Autostart bei Anmeldung — standardmäßig an.
    var launchAtLogin: Bool {
        get { defaults.object(forKey: "launchAtLogin") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }

    var windowCloseAction: WindowCloseAction {
        get { WindowCloseAction(rawValue: defaults.string(forKey: "windowCloseAction") ?? "") ?? .ask }
        set { defaults.set(newValue.rawValue, forKey: "windowCloseAction") }
    }

    /// Name, in dessen Auftrag die KI schreibt (Assist) und der im Meeting-Transkript
    /// als „Ich" gilt. Leer = die Prompts kommen ohne Namen aus.
    var userName: String {
        get { (defaults.string(forKey: "userName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { defaults.set(newValue, forKey: "userName") }
    }

    /// UID des Mikrofons für Diktat und Meetings. Leer = Systemstandard.
    /// Bewusst die UID und nicht die numerische ID: Letztere ändert sich beim
    /// Neuanstecken des Geräts.
    var inputDeviceUID: String? {
        get {
            let value = defaults.string(forKey: "inputDeviceUID") ?? ""
            return value.isEmpty ? nil : value
        }
        set { defaults.set(newValue ?? "", forKey: "inputDeviceUID") }
    }

    /// Echo-Unterdrückung während Meetings — verhindert, dass die über
    /// Lautsprecher wiedergegebene Gegenseite im Mikrofonkanal landet.
    var meetingEchoCancellation: Bool {
        get { defaults.object(forKey: "meetingEchoCancellation") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "meetingEchoCancellation") }
    }

    var assistProvider: AssistProviderChoice {
        get { AssistProviderChoice(rawValue: defaults.string(forKey: "assistProvider") ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "assistProvider") }
    }

    /// Einmal bestätigter Hinweis zur Rechtslage bei Meeting-Aufzeichnungen.
    var meetingLegalNoticeAccepted: Bool {
        get { defaults.bool(forKey: "meetingLegalNoticeAccepted") }
        set { defaults.set(newValue, forKey: "meetingLegalNoticeAccepted") }
    }

    // MARK: - Custom prompts (empty/unset = built-in default)

    static func promptKey(for languageCode: String) -> String {
        languageCode.hasPrefix("de") ? "customPrompt.de" : "customPrompt.en"
    }

    static func assistPromptKey(for languageCode: String) -> String {
        languageCode.hasPrefix("de") ? "assistPrompt.de" : "assistPrompt.en"
    }

    /// Returns the user's custom prompt for the language, or nil to use the default.
    func customPrompt(for languageCode: String) -> String? {
        Self.nonEmpty(defaults.string(forKey: Self.promptKey(for: languageCode)))
    }

    func customAssistPrompt(for languageCode: String) -> String? {
        Self.nonEmpty(defaults.string(forKey: Self.assistPromptKey(for: languageCode)))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

/// Welche KI den Assist-Text verfasst.
///
/// Standard ist bewusst die Claude CLI: Das lokale Apple-Intelligence-Modell
/// befolgt nachweislich Anweisungen, die im eingefügten Fremdtext stehen
/// (Prompt Injection), und formuliert bei Antworten deutlich schwächer.
enum AssistProviderChoice: String, CaseIterable {
    case auto
    case claudeCLI
    case appleIntelligence

    var title: String {
        switch self {
        case .auto: return "Automatisch (Claude CLI → Apple Intelligence)"
        case .claudeCLI: return "Nur Claude CLI (empfohlen)"
        case .appleIntelligence: return "Nur Apple Intelligence (lokal, unsicherer)"
        }
    }
}

/// Was beim Schließen des Hauptfensters passiert.
enum WindowCloseAction: String, CaseIterable {
    case ask
    case background
    case quit

    var title: String {
        switch self {
        case .ask: return "Nachfragen"
        case .background: return "Im Hintergrund weiterlaufen"
        case .quit: return "App komplett beenden"
        }
    }
}
