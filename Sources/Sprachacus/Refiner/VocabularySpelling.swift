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
        }
        return result
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
