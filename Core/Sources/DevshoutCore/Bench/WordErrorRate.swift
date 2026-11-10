import Foundation

/// One step of the word-level alignment between a reference and a hypothesis.
public struct AlignedWord: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case match, substitution, deletion, insertion }

    public var kind: Kind
    /// The reference word (nil for an insertion).
    public var reference: String?
    /// The hypothesis word (nil for a deletion).
    public var hypothesis: String?

    public init(kind: Kind, reference: String?, hypothesis: String?) {
        self.kind = kind
        self.reference = reference
        self.hypothesis = hypothesis
    }
}

/// Word error rate with its breakdown and the alignment that produced it.
public struct WERResult: Sendable, Hashable {
    public var referenceWordCount: Int
    public var hypothesisWordCount: Int
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    /// Full alignment, in order, matches included.
    public var alignment: [AlignedWord]

    public init(referenceWordCount: Int, hypothesisWordCount: Int, substitutions: Int, deletions: Int,
                insertions: Int, alignment: [AlignedWord]) {
        self.referenceWordCount = referenceWordCount
        self.hypothesisWordCount = hypothesisWordCount
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.alignment = alignment
    }

    public var errors: Int { substitutions + deletions + insertions }
    public var hits: Int { referenceWordCount - substitutions - deletions }

    /// (S + D + I) / N. With an empty reference it is the number of inserted words (0 when the hypothesis is
    /// empty too), so it can exceed 1.
    public var wer: Double { Double(errors) / Double(max(referenceWordCount, 1)) }

    /// Only the steps that are errors, in order.
    public var errorSteps: [AlignedWord] { alignment.filter { $0.kind != .match } }

    /// Human-readable error list, one per line: `~ corsair → CORSIA`, `- the`, `+ um`.
    /// Words are the normalised (lowercase) forms. `limit` caps the number of lines.
    public func errorSummary(limit: Int? = nil) -> String {
        var lines: [String] = []
        for step in errorSteps {
            switch step.kind {
            case .substitution: lines.append("~ \(step.reference ?? "") → \(step.hypothesis ?? "")")
            case .deletion: lines.append("- \(step.reference ?? "")")
            case .insertion: lines.append("+ \(step.hypothesis ?? "")")
            case .match: break
            }
        }
        if let limit, lines.count > limit {
            let more = lines.count - limit
            lines = Array(lines.prefix(limit)) + ["… and \(more) more"]
        }
        return lines.joined(separator: "\n")
    }

    /// Two aligned rows in the style of sclite: `REF:` and `HYP:` with `***` where a word is missing and errors
    /// in capitals. Wrapped at `width` characters.
    public func alignedRows(width: Int = 100) -> String {
        var refCells: [String] = []
        var hypCells: [String] = []
        for step in alignment {
            let r = step.reference ?? ""
            let h = step.hypothesis ?? ""
            let cellWidth = max(r.count, h.count, step.kind == .match ? 0 : 3)
            switch step.kind {
            case .match:
                refCells.append(r.padding(toLength: cellWidth, withPad: " ", startingAt: 0))
                hypCells.append(h.padding(toLength: cellWidth, withPad: " ", startingAt: 0))
            case .substitution:
                refCells.append(r.uppercased().padding(toLength: cellWidth, withPad: " ", startingAt: 0))
                hypCells.append(h.uppercased().padding(toLength: cellWidth, withPad: " ", startingAt: 0))
            case .deletion:
                refCells.append(r.uppercased().padding(toLength: cellWidth, withPad: " ", startingAt: 0))
                hypCells.append("***".padding(toLength: cellWidth, withPad: " ", startingAt: 0))
            case .insertion:
                refCells.append("***".padding(toLength: cellWidth, withPad: " ", startingAt: 0))
                hypCells.append(h.uppercased().padding(toLength: cellWidth, withPad: " ", startingAt: 0))
            }
        }
        var blocks: [String] = []
        var start = 0
        while start < refCells.count {
            var end = start
            var used = 5
            while end < refCells.count, used + refCells[end].count + 1 <= width || end == start {
                used += refCells[end].count + 1
                end += 1
            }
            let ref = "REF: " + refCells[start..<end].joined(separator: " ")
            let hyp = "HYP: " + hypCells[start..<end].joined(separator: " ")
            blocks.append(trimTrailingSpaces(ref) + "\n" + trimTrailingSpaces(hyp))
            start = end
        }
        return blocks.joined(separator: "\n\n")
    }

    private func trimTrailingSpaces(_ s: String) -> String {
        var s = s
        while s.last == " " { s.removeLast() }
        return s
    }
}

public enum WordErrorRate {
    /// Normalises both texts with `BenchText` and aligns them word by word (Levenshtein distance with unit costs).
    /// When several alignments have the same cost, matches and substitutions are preferred over deletions, and
    /// deletions over insertions, so results are deterministic.
    public static func compute(reference: String, hypothesis: String) -> WERResult {
        compute(referenceWords: BenchText.words(reference), hypothesisWords: BenchText.words(hypothesis))
    }

    /// As `compute(reference:hypothesis:)`, for words that are already normalised.
    public static func compute(referenceWords ref: [String], hypothesisWords hyp: [String]) -> WERResult {
        let n = ref.count
        let m = hyp.count
        // cost[i][j] = edit distance between ref[..<i] and hyp[..<j].
        var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let diagonal = cost[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1)
                    cost[i][j] = min(diagonal, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
                }
            }
        }

        // Walk back from the end, preferring diagonal moves, then deletions, then insertions.
        var steps: [AlignedWord] = []
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1) {
                let same = ref[i - 1] == hyp[j - 1]
                steps.append(AlignedWord(kind: same ? .match : .substitution, reference: ref[i - 1], hypothesis: hyp[j - 1]))
                i -= 1
                j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                steps.append(AlignedWord(kind: .deletion, reference: ref[i - 1], hypothesis: nil))
                i -= 1
            } else {
                steps.append(AlignedWord(kind: .insertion, reference: nil, hypothesis: hyp[j - 1]))
                j -= 1
            }
        }
        steps.reverse()

        return WERResult(
            referenceWordCount: n,
            hypothesisWordCount: m,
            substitutions: steps.filter { $0.kind == .substitution }.count,
            deletions: steps.filter { $0.kind == .deletion }.count,
            insertions: steps.filter { $0.kind == .insertion }.count,
            alignment: steps
        )
    }
}
