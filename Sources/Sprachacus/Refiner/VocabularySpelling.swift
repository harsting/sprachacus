import Foundation

/// Setzt die hinterlegte Schreibweise eigener Begriffe im fertigen Text durch.
///
/// Die Spracherkennung schreibt Kürzel nach eigenem Gutdünken („21DX" statt
/// „21Dx"), und die KI-Korrektur bittet man zwar darum, die Begriffe
/// unverändert zu übernehmen — verlassen kann man sich darauf nicht. Deshalb
/// wird die Schreibweise hinterher hart gesetzt: gleiche Buchstaben, nur die
/// Groß- und Kleinschreibung wird korrigiert.
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

    /// Fängt zusätzlich knappe Verhörer ab: Das Modell schrieb „Doctevo"
    /// statt „doctevio" — ein Buchstabe fehlt, die reine Groß-/Kleinschreibung
    /// greift da nicht.
    ///
    /// Bewusst eng gefasst: nur Begriffe ab sechs Zeichen, nur ein Fehler
    /// Abstand, und niemals dort, wo das gefundene Wort mit dem Begriff
    /// anfängt — „Rentokils" ist der Genitiv von „Rentokil" und darf nicht
    /// zurückgekürzt werden.
    private static func replaceNearMisses(_ term: String, in text: String) -> String {
        guard term.count >= 6, !term.contains(" ") else { return text }
        let lowerTerm = term.lowercased()
        var result = ""
        var wort = ""
        func spuele() {
            if !wort.isEmpty {
                let lower = wort.lowercased()
                if lower != lowerTerm,
                   abs(wort.count - term.count) <= 1,
                   !lower.hasPrefix(lowerTerm),
                   editDistance(lower, lowerTerm) == 1 {
                    result += term
                } else {
                    result += wort
                }
                wort = ""
            }
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

    /// Levenshtein-Abstand, abgebrochen sobald er über eins liegt.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var vorherige = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var aktuelle = [i] + Array(repeating: 0, count: y.count)
            for j in 1...max(y.count, 1) where !y.isEmpty {
                aktuelle[j] = x[i-1] == y[j-1]
                    ? vorherige[j-1]
                    : 1 + min(vorherige[j-1], vorherige[j], aktuelle[j-1])
            }
            vorherige = aktuelle
        }
        return vorherige[y.count]
    }

    private static func replace(_ term: String, in text: String) -> String {
        // Leerzeichen im Begriff dürfen im Text beliebig viele sein.
        let escaped = term
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "\\s+")
        guard !escaped.isEmpty else { return text }
        // Keine Treffer mitten in längeren Wörtern.
        let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        // Von hinten ersetzen, damit die Bereiche gültig bleiben.
        for match in regex.matches(in: text, range: range).reversed() {
            guard let found = Range(match.range, in: result) else { continue }
            // Mehrere Wörter im Text auf die Schreibweise des Begriffs bringen,
            // dabei die vorhandenen Trennzeichen beibehalten.
            result.replaceSubrange(found, with: spelled(term, like: String(result[found])))
        }
        return result
    }

    /// Nimmt die Schreibweise des Begriffs, behält aber die Leerzeichen des
    /// gefundenen Textes bei.
    private static func spelled(_ term: String, like found: String) -> String {
        let termWords = term.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard termWords.count > 1 else { return term }
        var result = ""
        var index = 0
        var buffer = ""
        for character in found {
            if character.isWhitespace {
                if !buffer.isEmpty {
                    result += index < termWords.count ? termWords[index] : buffer
                    index += 1
                    buffer = ""
                }
                result.append(character)
            } else {
                buffer.append(character)
            }
        }
        if !buffer.isEmpty {
            result += index < termWords.count ? termWords[index] : buffer
        }
        return result
    }
}
