import Foundation

/// Setzt die hinterlegte Schreibweise eigener Begriffe im fertigen Text durch.
///
/// Die Spracherkennung schreibt Kürzel nach eigenem Gutdünken: „21DX" oder
/// „21 DX" statt „21Dx", „Staff Connect" statt „StaffConnect", und bei
/// Firmennamen hört sie auch mal daneben („Toktavio" statt „doctevio").
/// Die KI-Korrektur bittet man zwar darum, die Begriffe unverändert zu
/// übernehmen — verlassen kann man sich darauf nicht, und einen Verhörer der
/// Erkennung kann sie ohnehin nicht wissen. Deshalb wird die Schreibweise
/// hinterher hart gesetzt.
enum VocabularySpelling {
    /// Wendet alle Begriffe an; längere zuerst, damit „21Dx Tool" nicht von
    /// „21Dx" zerlegt wird.
    static func apply(_ text: String, terms: [String]) -> String {
        var result = text
        for term in terms.sorted(by: { $0.count > $1.count }) where term.count >= 2 {
            result = replace(term, in: result)
            result = replaceNearMisses(term, in: result)
        }
        return result
    }

    // MARK: - Gleiche Buchstaben, andere Schreibweise

    private static func replace(_ term: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern(for: term),
                                                   options: [.caseInsensitive]) else {
            return text
        }
        var result = text
        let range = NSRange(text.startIndex..., in: text)
        // Von hinten ersetzen, damit die Bereiche gültig bleiben.
        for match in regex.matches(in: text, range: range).reversed() {
            guard let found = Range(match.range, in: result) else { continue }
            result.replaceSubrange(found, with: term)
        }
        return result
    }

    /// Der Begriff darf im Text anders getrennt sein, als er hinterlegt ist:
    /// „21Dx" findet auch „21 DX" und „21-dx", „StaffConnect" auch
    /// „Staff Connect", „Dropdown-Menü" auch „Dropdown Menü". Nur die Wortgrenze
    /// bleibt Pflicht, damit nichts mitten in längeren Wörtern getroffen wird.
    private static func pattern(for term: String) -> String {
        let flexible = "[ \t]*-?[ \t]*"
        let words = term.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { word in
                parts(of: word)
                    .map { NSRegularExpression.escapedPattern(for: $0) }
                    .joined(separator: flexible)
            }
        guard !words.isEmpty else { return "(?!)" }
        return "(?<![\\p{L}\\p{N}])" + words.joined(separator: "[ \t]+") + "(?![\\p{L}\\p{N}])"
    }

    /// Zerlegt einen Begriff dort, wo die Erkennung gern ein Leerzeichen
    /// einfügt: zwischen Zahl und Buchstabe („21|Dx"), beim Wechsel von klein
    /// auf groß („Staff|Connect") und am Bindestrich.
    private static func parts(of word: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character?
        for character in word {
            if character == "-" {
                if !current.isEmpty { result.append(current) }
                current = ""
                previous = nil
                continue
            }
            if let last = previous, isBoundary(last, character) {
                result.append(current)
                current = ""
            }
            current.append(character)
            previous = character
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func isBoundary(_ left: Character, _ right: Character) -> Bool {
        if left.isNumber != right.isNumber { return true }
        if left.isLowercase && right.isUppercase { return true }
        return false
    }

    // MARK: - Verhörer

    /// Fängt zusätzlich Verhörer ab: Das Modell schrieb „Toktavio" statt
    /// „doctevio" — stimmhaft und stimmlos klingen für die Erkennung gleich
    /// (d/t, g/k, c/k, b/p, w/f/v, s/z), die reine Groß- und Kleinschreibung
    /// greift da nicht.
    ///
    /// Bewusst eng gefasst: nur Begriffe ab sechs Zeichen, nur ein Laut
    /// Abstand, und niemals dort, wo das gefundene Wort den Begriff als Anfang
    /// enthält — „Rentokils" ist der Genitiv von „Rentokil" und darf nicht
    /// zurückgekürzt werden.
    private static func replaceNearMisses(_ term: String, in text: String) -> String {
        guard term.count >= 6, !term.contains(" "), !term.contains("-") else { return text }
        let lowerTerm = term.lowercased()
        let termSound = sound(term)
        var result = ""
        var wort = ""
        func spuele() {
            if !wort.isEmpty {
                result += matches(wort) ? term : wort
                wort = ""
            }
        }
        func matches(_ wort: String) -> Bool {
            let lower = wort.lowercased()
            guard lower != lowerTerm else { return false }
            // Ableitungen und Zusammensetzungen nicht antasten.
            guard !(lower.count > lowerTerm.count && lower.hasPrefix(lowerTerm)) else { return false }
            let wortSound = sound(wort)
            guard !(wortSound.count > termSound.count && wortSound.hasPrefix(termSound)) else { return false }
            guard abs(wortSound.count - termSound.count) <= 1 else { return false }
            return editDistance(wortSound, termSound) <= 1
        }
        for zeichen in text {
            if zeichen.isLetter || zeichen.isNumber {
                wort.append(zeichen)
            } else {
                spuele()
                result.append(zeichen)
            }
        }
        spuele()
        return result
    }

    /// Reduziert ein Wort auf seinen Klang, soweit man das ohne Phonetik
    /// behaupten kann: Umlaute aufgelöst und die Buchstabenpaare
    /// zusammengelegt, die gleich klingen. Vokale bleiben unangetastet —
    /// sonst rückt zu vieles zu nah zusammen („Mahler" wäre sonst „Müller").
    private static func sound(_ word: String) -> String {
        var result = ""
        for zeichen in word.lowercased() {
            switch zeichen {
            case "ä": result += "a"
            case "ö": result += "o"
            case "ü": result += "u"
            case "ß": result += "ss"
            case "d": result += "t"
            case "g", "c", "q", "k": result += "k"
            case "b": result += "p"
            case "w", "f": result += "v"
            case "z": result += "s"
            case "y", "j": result += "i"
            default: result.append(zeichen)
            }
        }
        return result
    }

    /// Levenshtein-Abstand.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var vorherige = Array(0...y.count)
        for i in 1...x.count {
            var aktuelle = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                aktuelle[j] = x[i-1] == y[j-1]
                    ? vorherige[j-1]
                    : 1 + min(vorherige[j-1], vorherige[j], aktuelle[j-1])
            }
            vorherige = aktuelle
        }
        return vorherige[y.count]
    }
}
