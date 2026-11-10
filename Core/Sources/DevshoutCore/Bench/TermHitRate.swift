import Foundation

/// How one glossary term fared in one sample.
public struct TermResult: Sendable, Hashable {
    public var term: String
    /// How many times the reference contains the term (exact spelling, case-sensitive, as a whole word).
    public var referenceCount: Int
    /// How many times the hypothesis contains it, same rules.
    public var hypothesisCount: Int

    public init(term: String, referenceCount: Int, hypothesisCount: Int) {
        self.term = term
        self.referenceCount = referenceCount
        self.hypothesisCount = hypothesisCount
    }

    /// Occurrences the hypothesis got right (never more than the reference has).
    public var found: Int { min(referenceCount, hypothesisCount) }
    /// The term is in the reference and the hypothesis has all of its occurrences.
    public var isHit: Bool { referenceCount > 0 && hypothesisCount >= referenceCount }
}

/// Jargon hit rate for one sample: of the glossary terms the reference contains, how many did the hypothesis
/// spell exactly right?
public struct TermHitResult: Sendable, Hashable {
    /// Only terms that occur in the reference, in the order given.
    public var terms: [TermResult]

    public init(terms: [TermResult]) { self.terms = terms }

    /// Term occurrences in the reference.
    public var total: Int { terms.reduce(0) { $0 + $1.referenceCount } }
    /// Term occurrences the hypothesis reproduced exactly.
    public var hits: Int { terms.reduce(0) { $0 + $1.found } }
    /// hits / total, or nil when the reference contains none of the terms.
    public var rate: Double? { total == 0 ? nil : Double(hits) / Double(total) }
    /// Terms the hypothesis got wrong or missed (for showing errors).
    public var missed: [TermResult] { terms.filter { $0.found < $0.referenceCount } }
}

public enum TermHitRate {
    /// For each term that occurs in `reference`, counts how often `hypothesis` has it spelled exactly the same.
    ///
    /// Matching is case-sensitive ("CORSIA" does not match "Corsia"; "My Supply" does not match "my supply") and
    /// needs word boundaries: a match must not touch a letter or digit on either side, so "NDC" is not found in
    /// "NDCs" and "AB-123" is not found in "AB-1234". Whitespace runs count as one space, and curly quotes count as
    /// straight ones. Duplicate terms (after trimming) are counted once. A term that occurs twice in the
    /// reference counts twice; the hypothesis scores `min(found, 2)`.
    public static func evaluate(terms: [String], reference: String, hypothesis: String) -> TermHitResult {
        let ref = BenchText.forTermMatching(reference)
        let hyp = BenchText.forTermMatching(hypothesis)
        var seen = Set<String>()
        var results: [TermResult] = []
        for raw in terms {
            let term = BenchText.forTermMatching(raw)
            guard !term.isEmpty else { continue }
            guard seen.insert(String(term)).inserted else { continue }
            let inReference = count(term, in: ref)
            guard inReference > 0 else { continue }
            results.append(TermResult(term: String(term), referenceCount: inReference, hypothesisCount: count(term, in: hyp)))
        }
        return TermHitResult(terms: results)
    }

    /// Ticket IDs such as AB-1234 found in `text` (two to five capital letters, a hyphen, digits), in order of
    /// first appearance. Handy for adding the reference's tickets to the term list.
    public static func ticketIDs(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])[A-Z]{2,5}-[0-9]+(?![A-Za-z0-9])") else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: match.range)
            if !out.contains(id) { out.append(id) }
        }
        return out
    }

    /// Terms to score a sample with: the glossary's terms, then any ticket IDs in the reference that the glossary
    /// does not already list.
    public static func termList(glossaryTerms: [String], reference: String) -> [String] {
        var out = glossaryTerms
        for id in ticketIDs(in: reference) where !out.contains(id) { out.append(id) }
        return out
    }

    /// Whole-word occurrences of `needle` in `haystack`, not overlapping.
    static func count(_ needle: [Character], in haystack: [Character]) -> Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        var count = 0
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == needle[0], Array(haystack[i..<(i + needle.count)]) == needle,
               isBoundary(haystack, before: i), isBoundary(haystack, after: i + needle.count - 1) {
                count += 1
                i += needle.count
            } else {
                i += 1
            }
        }
        return count
    }

    private static func isBoundary(_ chars: [Character], before index: Int) -> Bool {
        index == 0 || !isWordCharacter(chars[index - 1])
    }

    private static func isBoundary(_ chars: [Character], after index: Int) -> Bool {
        index + 1 >= chars.count || !isWordCharacter(chars[index + 1])
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
}

/// A small reader for the glossary format (PLAN §6.1), only for the bench: it lists the bold terms under
/// `## Terms` and `## People`. The real parser is `GlossaryParser`; this exists so the bench needs nothing else.
public enum BenchGlossaryTerms {
    public static func terms(fromMarkdown markdown: String) -> [String] {
        var section = ""
        var out: [String] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                section = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard section == "terms" || section == "people" else { continue }
            // Top-level bullets only: "- **Term**" or "- !**Term**".
            guard line.hasPrefix("- ") else { continue }
            var rest = line.dropFirst(2).drop(while: { $0 == " " })
            if rest.hasPrefix("!") { rest = rest.dropFirst() }
            guard rest.hasPrefix("**") else { continue }
            let body = rest.dropFirst(2)
            guard let close = body.range(of: "**") else { continue }
            let term = body[body.startIndex..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if !term.isEmpty, !out.contains(term) { out.append(term) }
        }
        return out
    }
}
