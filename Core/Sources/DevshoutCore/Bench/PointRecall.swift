import Foundation

/// One group of acceptable phrasings: the group is satisfied when the text contains any one of them.
public struct KeywordGroup: Sendable, Hashable {
    public var alternatives: [String]

    public init(alternatives: [String]) { self.alternatives = alternatives }
}

/// One point of the ramble: a short label and what a text must contain to count as covering it.
public struct RamblePoint: Sendable, Hashable {
    public var number: Int
    public var label: String
    /// Guidance for the speaker (not used for scoring).
    public var prompt: String?
    /// Every group must be satisfied (all-of), each by any one of its alternatives (any-of).
    public var requirements: [KeywordGroup]
    /// Phrases the speaker corrected away. They never affect `covered`, but a clean-up that was meant to keep only
    /// the correction should not contain them (see `PointCoverage.retractedFound`).
    public var retracted: [String]

    public init(number: Int, label: String, prompt: String? = nil, requirements: [KeywordGroup],
                retracted: [String] = []) {
        self.number = number
        self.label = label
        self.prompt = prompt
        self.requirements = requirements
        self.retracted = retracted
    }
}

/// How one point fared against one text.
public struct PointCoverage: Sendable, Hashable {
    public var point: RamblePoint
    /// Per requirement group: which alternative matched (nil when none did), in the group order.
    public var matched: [String?]
    /// Retracted phrases still present in the text.
    public var retractedFound: [String]

    public init(point: RamblePoint, matched: [String?], retractedFound: [String]) {
        self.point = point
        self.matched = matched
        self.retractedFound = retractedFound
    }

    public var matchedGroups: Int { matched.filter { $0 != nil }.count }
    public var totalGroups: Int { matched.count }
    /// Every requirement group is satisfied.
    public var covered: Bool { matched.allSatisfy { $0 != nil } }
    /// Requirement groups with no match, as their alternatives joined with " | ".
    public var missingGroups: [String] {
        zip(point.requirements, matched).filter { $0.1 == nil }.map { $0.0.alternatives.joined(separator: " | ") }
    }
}

/// Which of the ramble's points a text covers (the "x/8" of the Structure benchmark).
public struct PointRecallResult: Sendable, Hashable {
    public var points: [PointCoverage]

    public init(points: [PointCoverage]) { self.points = points }

    public var total: Int { points.count }
    public var coveredCount: Int { points.filter(\.covered).count }
    /// coveredCount / total, or nil when there are no points.
    public var recall: Double? { total == 0 ? nil : Double(coveredCount) / Double(total) }
    public var missing: [PointCoverage] { points.filter { !$0.covered } }
    /// Points whose corrected-away phrases are still in the text.
    public var withRetracted: [PointCoverage] { points.filter { !$0.retractedFound.isEmpty } }
    /// "7/8".
    public var summary: String { "\(coveredCount)/\(total)" }
}

public enum PointRecall {
    /// Checks each point against `text`. Matching works on normalised words (`BenchText`), so it ignores case and
    /// punctuation ("AB-1234" matches "ab 1234"), and a phrase must match whole words in order: "12" does not
    /// match "120", and "supply table" does not match "supply tables".
    public static func evaluate(points: [RamblePoint], text: String) -> PointRecallResult {
        let words = BenchText.words(text)
        let coverage = points.map { point -> PointCoverage in
            let matched = point.requirements.map { group in
                group.alternatives.first { contains(words, phrase: $0) }
            }
            let retracted = point.retracted.filter { contains(words, phrase: $0) }
            return PointCoverage(point: point, matched: matched, retractedFound: retracted)
        }
        return PointRecallResult(points: coverage)
    }

    /// True when `phrase` (normalised) occurs as a run of whole words in `words`. An empty phrase never matches.
    static func contains(_ words: [String], phrase: String) -> Bool {
        let needle = BenchText.words(phrase)
        guard !needle.isEmpty, words.count >= needle.count else { return false }
        for start in 0...(words.count - needle.count) where words[start] == needle[0] {
            if Array(words[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }
}
