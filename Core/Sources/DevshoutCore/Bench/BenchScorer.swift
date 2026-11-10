import Foundation

/// All three metrics for one hypothesis.
public struct BenchScore: Sendable, Hashable {
    public var wer: WERResult
    public var terms: TermHitResult
    /// Nil when no points were given (the sentences have none; only the ramble does).
    public var points: PointRecallResult?

    public init(wer: WERResult, terms: TermHitResult, points: PointRecallResult?) {
        self.wer = wer
        self.terms = terms
        self.points = points
    }
}

public enum BenchScorer {
    /// Scores `hypothesis` against `reference`. Ticket IDs found in the reference are added to the glossary terms.
    /// Point recall is checked on the hypothesis text (the cleaned text in Tidy and Structure runs).
    public static func score(reference: String, hypothesis: String, glossaryTerms: [String] = [],
                             points: [RamblePoint]? = nil) -> BenchScore {
        BenchScore(
            wer: WordErrorRate.compute(reference: reference, hypothesis: hypothesis),
            terms: TermHitRate.evaluate(terms: TermHitRate.termList(glossaryTerms: glossaryTerms, reference: reference),
                                        reference: reference, hypothesis: hypothesis),
            points: points.map { PointRecall.evaluate(points: $0, text: hypothesis) }
        )
    }
}
