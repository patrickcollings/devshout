import Foundation

/// Text normalisation shared by every bench metric.
///
/// Scoring ignores case, punctuation and layout, because speech-to-text engines and Claude disagree about those
/// all the time and they are not what the spike measures. (Exact spelling of jargon is measured separately by
/// `TermHitRate`, which does *not* normalise case.)
public enum BenchText {
    /// Lowercase, strip punctuation, collapse whitespace, straighten curly quotes and treat dashes and hyphens as
    /// word breaks (so "AB-1234" scores the same as "AB 1234", and "well—known" is two words).
    ///
    /// What is kept: letters and digits (accents included), an apostrophe between two letters ("don't"), a full
    /// stop between two digits ("3.5"). A thousands separator is dropped ("1,000" becomes "1000"). Everything else,
    /// including "%" and "£", becomes a word break.
    public static func normalise(_ text: String) -> String {
        words(text).joined(separator: " ")
    }

    /// The normalised text split into words.
    public static func words(_ text: String) -> [String] {
        let chars = Array(text.precomposedStringWithCanonicalMapping.lowercased()).map(straighten)
        var out = ""
        out.reserveCapacity(chars.count)
        for i in chars.indices {
            let c = chars[i]
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c.isLetter || c.isNumber {
                out.append(c)
            } else if c == "'", let prev, let next, prev.isLetter, next.isLetter {
                out.append(c)
            } else if c == ".", let prev, let next, prev.isNumber, next.isNumber {
                out.append(c)
            } else if c == ",", let prev, prev.isNumber, isThousandsGroup(chars, after: i) {
                continue
            } else {
                out.append(" ")
            }
        }
        return out.split(separator: " ").map(String.init)
    }

    /// Curly quotes to straight ones. Dashes are left alone here: they are word breaks in `words`.
    static func straighten(_ c: Character) -> Character {
        switch c {
        case "\u{2018}", "\u{2019}", "\u{201B}", "\u{02BC}", "\u{2032}": return "'"
        case "\u{201C}", "\u{201D}", "\u{201F}", "\u{2033}": return "\""
        default: return c
        }
    }

    /// True when the comma at `index` is followed by exactly three digits and then a non-digit ("1,000").
    private static func isThousandsGroup(_ chars: [Character], after index: Int) -> Bool {
        let start = index + 1
        guard start + 3 <= chars.count else { return false }
        guard chars[start..<(start + 3)].allSatisfy({ $0.isNumber }) else { return false }
        return start + 3 == chars.count || !chars[start + 3].isNumber
    }

    /// Text prepared for exact, case-sensitive term matching: composed Unicode, straight quotes, dashes between
    /// words left as typed, and every run of whitespace collapsed to one space.
    static func forTermMatching(_ text: String) -> [Character] {
        var out: [Character] = []
        var lastWasSpace = true
        for c in text.precomposedStringWithCanonicalMapping {
            if c.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(straighten(c))
                lastWasSpace = false
            }
        }
        if out.last == " " { out.removeLast() }
        return out
    }
}
