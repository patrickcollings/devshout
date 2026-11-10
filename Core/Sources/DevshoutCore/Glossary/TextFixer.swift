import Foundation

/// One change the `TextFixer` made.
public struct TextReplacement: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// A `heard:` mishearing (or an accent-less spelling of a name) replaced by the correct term.
        case mishearing
        /// A `{n}` pattern such as a ticket ID ("a b one two three four" → "AB-1234").
        case pattern
    }

    /// The text that was replaced, as it was in the input.
    public var original: String
    /// What it became.
    public var replacement: String
    /// The glossary entry's term (for patterns, the template such as `AB-{n}`).
    public var term: String
    public var kind: Kind
    /// Where `original` was in the input, in UTF-16 code units (as `NSRange` and `NSAttributedString` count).
    public var inputRange: Range<Int>

    public init(original: String, replacement: String, term: String, kind: Kind, inputRange: Range<Int>) {
        self.original = original
        self.replacement = replacement
        self.term = term
        self.kind = kind
        self.inputRange = inputRange
    }
}

public struct TextFixResult: Sendable, Hashable {
    public var text: String
    /// In the order they appear in the text. Matches that were already correct are not listed.
    public var replacements: [TextReplacement]

    public init(text: String, replacements: [TextReplacement]) {
        self.text = text
        self.replacements = replacements
    }
}

/// Applies the glossary's deterministic fixes to a transcript, in every mode (PLAN §6.3, §3.1 step 6):
/// - `heard:` mishearings → the correct term. Whole words, case-insensitive, longest match first.
///   A name or term with accents is also restored when written without them ("Siobhan" → "Siobhán").
/// - Patterns: `AB-{n}` fixes "AB 1234", "ab1234", "a b 1234", "A.B. 1234", spelled-out numbers
///   ("a b one two three four", "AB twelve thirty-four") and each `heard:` form ("ABE {n}").
/// - Nothing inside a URL, an email address or backtick code (`inline` or fenced) is changed.
///
/// Build one per glossary and reuse it: the regexes are compiled in `init`.
public struct TextFixer: Sendable {
    struct Rule: Sendable {
        var regex: RegexBox
        var term: String
        var kind: TextReplacement.Kind
        /// The entry's position in the file: earlier wins a tie.
        var order: Int
    }

    let rules: [Rule]

    public init(glossary: Glossary) {
        var rules: [Rule] = []
        for (order, item) in glossary.allEntries.enumerated() {
            let entry = item.entry
            if entry.isPattern {
                for template in [entry.term] + entry.heard where template.contains(GlossaryEntry.numberPlaceholder) {
                    if let re = TextFixer.patternRegex(template) {
                        rules.append(Rule(regex: re, term: entry.term, kind: .pattern, order: order))
                    }
                }
            } else {
                for phrase in entry.heard where !phrase.contains(GlossaryEntry.numberPlaceholder) {
                    if let re = TextFixer.phraseRegex(phrase, term: entry.term) {
                        rules.append(Rule(regex: re, term: entry.term, kind: .mishearing, order: order))
                    }
                }
                let folded = entry.term.folding(options: [.diacriticInsensitive], locale: nil)
                if folded != entry.term, let re = TextFixer.phraseRegex(folded) {
                    rules.append(Rule(regex: re, term: entry.term, kind: .mishearing, order: order))
                }
            }
        }
        self.rules = rules
    }

    /// Whether the glossary gave the fixer anything to do.
    public var isEmpty: Bool { rules.isEmpty }

    /// One-off convenience. Prefer building a `TextFixer` once per glossary.
    public static func fix(_ text: String, glossary: Glossary) -> TextFixResult {
        TextFixer(glossary: glossary).fix(text)
    }

    public func fix(_ text: String) -> TextFixResult {
        guard !rules.isEmpty, !text.isEmpty else { return TextFixResult(text: text, replacements: []) }
        let utf16 = text.utf16
        let protected = TextFixer.protectedRanges(in: text)

        struct Candidate {
            var range: NSRange
            var replacement: String
            var rule: Int
        }
        var candidates: [Candidate] = []
        for (ruleIndex, rule) in rules.enumerated() {
            for match in rule.regex.matches(in: text) {
                switch rule.kind {
                case .mishearing:
                    let original = text.substring(match.range)
                    candidates.append(Candidate(range: match.range,
                                                replacement: TextFixer.matchCase(rule.term, to: original), rule: ruleIndex))
                case .pattern:
                    if let (range, replacement) = TextFixer.resolvePattern(match, template: rule.term, in: text) {
                        candidates.append(Candidate(range: range, replacement: replacement, rule: ruleIndex))
                    }
                }
            }
        }
        // Longest match first, then the earliest in the text, then the earliest in the glossary.
        candidates.sort {
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            return rules[$0.rule].order < rules[$1.rule].order
        }
        var accepted: [Candidate] = []
        for c in candidates where c.range.length > 0 {
            if protected.contains(where: { NSIntersectionRange($0, c.range).length > 0 }) { continue }
            if accepted.contains(where: { NSIntersectionRange($0.range, c.range).length > 0 }) { continue }
            accepted.append(c)
        }
        accepted.sort { $0.range.location < $1.range.location }

        var out = ""
        var replacements: [TextReplacement] = []
        var cursor = utf16.startIndex
        for c in accepted {
            guard let r = Range(c.range, in: text) else { continue }
            out += text[cursor..<r.lowerBound]
            let original = String(text[r])
            out += c.replacement
            cursor = r.upperBound
            if original != c.replacement {
                replacements.append(TextReplacement(original: original, replacement: c.replacement, term: rules[c.rule].term,
                                                    kind: rules[c.rule].kind,
                                                    inputRange: c.range.location..<(c.range.location + c.range.length)))
            }
        }
        out += text[cursor...]
        return TextFixResult(text: out, replacements: replacements)
    }

    // MARK: - Building rules

    static let wordBefore = #"(?<![\p{L}\p{N}_])"#
    static let wordAfter = #"(?![\p{L}\p{N}_])"#
    /// What may separate the letters of a spelled acronym, or the prefix of a pattern from its number.
    static let separator = #"[\s.\-–—:#]*"#

    /// A whole-phrase, case-insensitive regex for a `heard:` phrase. Words may be split by spaces or hyphens;
    /// a phrase of single letters ("N D C") also matches "NDC" and "N.D.C".
    ///
    /// With a multi-word `term`, words of the term written next to the mishearing are taken in too, so
    /// "Chevonne Murphy" becomes "Siobhán Murphy" (not "Siobhán Murphy Murphy") when only the first name is
    /// listed as heard.
    static func phraseRegex(_ phrase: String, term: String? = nil) -> RegexBox? {
        let words = splitWords(phrase)
        // A phrase of only punctuation ("." or "-") would rewrite every full stop.
        guard !words.isEmpty, phrase.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let spelled = words.count > 1 && words.allSatisfy { $0.count == 1 && $0.first!.isLetter }
        let joiner = spelled ? #"[\s.\-]*"# : #"[\s\-]+"#
        var body = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: joiner)
        if let term {
            let termWords = term.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
            if termWords.count > 1 {
                // Longest first, so the regex prefers taking in more of the term.
                let prefixes = (1..<termWords.count).reversed().map { termWords[0..<$0].joined(separator: #"\s+"#) }
                let suffixes = (1..<termWords.count).map { termWords[$0...].joined(separator: #"\s+"#) }
                body = "(?:(?:" + prefixes.joined(separator: "|") + #")\s+)?"# + body
                    + #"(?:\s+(?:"# + suffixes.joined(separator: "|") + ")" + wordAfter + ")?"
            }
        }
        let first = words.first!.first!, last = words.last!.last!
        let pattern = (isWordCharacter(first) ? wordBefore : "") + body + (isWordCharacter(last) ? wordAfter : "")
        return RegexBox(compiling: pattern, options: [.caseInsensitive])
    }

    static func splitWords(_ phrase: String) -> [String] {
        phrase.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
    }

    static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    /// A regex for a template with `{n}` placeholders, each captured as a run of number tokens.
    /// Nil for a template that is only a number (it would rewrite every number in the text).
    static func patternRegex(_ template: String) -> RegexBox? {
        let parts = template.components(separatedBy: GlossaryEntry.numberPlaceholder)
        let literals = parts.joined()
        guard literals.contains(where: { $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol }) else { return nil }

        var pattern = wordBefore
        for (index, part) in parts.enumerated() {
            let isFirst = index == 0, isLast = index == parts.count - 1
            pattern += literalPattern(part, leading: isFirst, trailing: isLast)
            if !isLast {
                if !part.isEmpty, isWordCharacter(part.last!) { pattern += separator }
                pattern += "(" + SpokenNumbers.runPattern + ")"
                let nextPart = parts[index + 1]
                if !nextPart.isEmpty, isWordCharacter(nextPart.first!) { pattern += separator }
            }
        }
        if let last = parts.last?.last, isWordCharacter(last) { pattern += wordAfter }
        return RegexBox(compiling: pattern, options: [.caseInsensitive])
    }

    /// A literal part of a template. Runs of 2–4 capitals may be spelled ("A B", "A.B."), punctuation and spaces
    /// between words are flexible, and punctuation at the very start or end of the template is required as written.
    static func literalPattern(_ literal: String, leading: Bool, trailing: Bool) -> String {
        var runs: [(text: String, word: Bool)] = []
        for c in literal {
            let w = c.isLetter || c.isNumber
            if let last = runs.last, last.word == w { runs[runs.count - 1].text.append(c) } else { runs.append((String(c), w)) }
        }
        var out = ""
        for (i, run) in runs.enumerated() {
            if run.word {
                let isAcronym = (2...4).contains(run.text.count) && run.text.allSatisfy { $0.isUppercase }
                if isAcronym {
                    out += run.text.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"[\s.\-]*"#) + #"\.?"#
                } else {
                    out += NSRegularExpression.escapedPattern(for: run.text)
                }
            } else if (leading && i == 0) || (trailing && i == runs.count - 1) {
                // Required as written. Spaces are allowed only on the inside edge, so the match never takes in
                // (and loses) the space before a leading "#" or after a trailing "%".
                let core = run.text.trimmingCharacters(in: .whitespaces)
                if core.isEmpty {
                    out += separator
                } else if leading && i == 0 {
                    out += NSRegularExpression.escapedPattern(for: core) + #"\s*"#
                } else {
                    out += #"\s*"# + NSRegularExpression.escapedPattern(for: core)
                }
            } else {
                out += separator
            }
        }
        return out
    }

    /// Reads the numbers in a pattern match and builds the replacement. The last number may stop early
    /// ("AB 1234 two days ago" keeps "two days ago"); a number in the middle must be read whole. A lone spoken
    /// "one" to "nine" is not read as a number ("the AB one" stays), but "AB 1" and "AB twelve" are.
    static func resolvePattern(_ match: NSTextCheckingResult, template: String, in text: String) -> (NSRange, String)? {
        let parts = template.components(separatedBy: GlossaryEntry.numberPlaceholder)
        let groups = parts.count - 1
        guard groups >= 1, match.numberOfRanges == groups + 1 else { return nil }
        var replacement = parts[0]
        var end = match.range.location + match.range.length
        for g in 1...groups {
            let groupRange = match.range(at: g)
            guard groupRange.location != NSNotFound, let r = Range(groupRange, in: text) else { return nil }
            let captured = String(text[r])
            guard let (digits, parsedEnd) = SpokenNumbers.parse(captured, allowLoneUnitWord: false) else { return nil }
            if parsedEnd != captured.endIndex {
                // Stopping early is fine only for a number at the very end of the template.
                guard g == groups, parts[g].isEmpty else { return nil }
                end = groupRange.location + captured[..<parsedEnd].utf16.count
            }
            replacement += digits + parts[g]
        }
        return (NSRange(location: match.range.location, length: end - match.range.location), replacement)
    }

    /// Keeps a lower-case term capitalised at the start of a sentence ("Proponent" stays capitalised).
    static func matchCase(_ term: String, to original: String) -> String {
        guard let t = term.first, t.isLowercase, let o = original.first, o.isUppercase else { return term }
        return t.uppercased() + term.dropFirst()
    }

    // MARK: - Protected text

    static let protectedPatterns: [RegexBox] = [
        RegexBox("```[\\s\\S]*?(?:```|\\z)"),                                   // fenced code (to the end if unclosed)
        RegexBox("`[^`\\n]*`"),                                                 // inline code
        RegexBox(#"(?i)\b[a-z][a-z0-9+.\-]*://[^\s<>"'`]+"#),                   // URLs with a scheme
        RegexBox(#"(?i)\bwww\.[^\s<>"'`]+"#),                                   // www.…
        RegexBox(#"[\p{L}\p{N}._%+\-]+@[\p{L}\p{N}\-]+(?:\.[\p{L}\p{N}\-]+)+"#), // email addresses
        RegexBox(#"(?i)\b[a-z0-9\-]+(?:\.[a-z0-9\-]+)*\.(?:com|org|net|io|dev|app|ai|co|uk|gov|edu)(?:/[^\s<>"'`]*)?(?![\p{L}\p{N}])"#), // bare domains
    ]

    static func protectedRanges(in text: String) -> [NSRange] {
        protectedPatterns.flatMap { $0.matches(in: text).map(\.range) }
    }
}
