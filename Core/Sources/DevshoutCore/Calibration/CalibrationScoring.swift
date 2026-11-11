import Foundation

// Scores for "Calibrate your voice". The measuring is the bench's (`WordErrorRate`, `TermHitRate`); this file adds
// up the sentences for each engine and decides which engine to recommend.

public extension EngineID {
    /// "Parakeet", "Whisper": the name used in sentences about the engines.
    var shortName: String {
        switch self {
        case .parakeetV3: "Parakeet"
        case .whisperLargeV3Turbo: "Whisper"
        }
    }
}

/// How one engine did on one sentence.
public struct CalibrationSentenceScore: Codable, Sendable, Hashable {
    public var sentenceID: String
    /// What the engine wrote (after the glossary's fixes, as the app would paste it in Raw mode).
    public var transcript: String
    public var audioSeconds: TimeInterval
    /// The engine's own time for this recording (not loading the model).
    public var processingSeconds: TimeInterval
    /// Words in the sentence, as scored.
    public var referenceWords: Int
    /// Words wrong, missing or added.
    public var wordErrors: Int
    /// Glossary terms (and ticket IDs) in the sentence.
    public var termCount: Int
    /// Of those, how many the engine spelled exactly right.
    public var termHits: Int

    public init(sentenceID: String, transcript: String, audioSeconds: TimeInterval, processingSeconds: TimeInterval,
                referenceWords: Int, wordErrors: Int, termCount: Int, termHits: Int) {
        self.sentenceID = sentenceID
        self.transcript = transcript
        self.audioSeconds = audioSeconds
        self.processingSeconds = processingSeconds
        self.referenceWords = referenceWords
        self.wordErrors = wordErrors
        self.termCount = termCount
        self.termHits = termHits
    }
}

/// How one engine did over the whole script.
public struct CalibrationEngineScore: Codable, Sendable, Hashable {
    public var engine: EngineID
    public var sentences: [CalibrationSentenceScore]

    public init(engine: EngineID, sentences: [CalibrationSentenceScore]) {
        self.engine = engine
        self.sentences = sentences
    }

    public var referenceWords: Int { sentences.reduce(0) { $0 + $1.referenceWords } }
    public var wordErrors: Int { sentences.reduce(0) { $0 + $1.wordErrors } }
    public var termCount: Int { sentences.reduce(0) { $0 + $1.termCount } }
    public var termHits: Int { sentences.reduce(0) { $0 + $1.termHits } }
    public var audioSeconds: TimeInterval { sentences.reduce(0) { $0 + $1.audioSeconds } }
    public var processingSeconds: TimeInterval { sentences.reduce(0) { $0 + $1.processingSeconds } }

    /// The share of words the engine got right, 0…1: one minus the word error rate over all the sentences
    /// together (so a long sentence counts for more than a short one), never below zero.
    public var wordAccuracy: Double {
        guard referenceWords > 0 else { return 0 }
        return max(0, 1 - Double(wordErrors) / Double(referenceWords))
    }

    /// The share of glossary terms spelled exactly right, or nil when the script had none.
    public var termHitRate: Double? {
        termCount == 0 ? nil : Double(termHits) / Double(termCount)
    }

    /// Seconds of processing for each minute of audio, or nil with no audio.
    public var secondsPerMinute: Double? {
        audioSeconds > 0 ? processingSeconds / audioSeconds * 60 : nil
    }
}

public enum CalibrationScorer {
    /// The glossary's terms for the term hit rate: every entry that isn't a `{n}` pattern. (Ticket IDs in a
    /// sentence are added by `TermHitRate.termList`.)
    public static func glossaryTerms(_ glossary: Glossary) -> [String] {
        glossary.allEntries.map(\.entry).filter { !$0.isPattern }.map(\.term)
    }

    /// The word alignment of a transcript against its sentence, on `CalibrationText` words.
    public static func alignment(reference: String, transcript: String) -> WERResult {
        WordErrorRate.compute(referenceWords: CalibrationText.words(reference),
                              hypothesisWords: CalibrationText.words(transcript))
    }

    /// One sentence's score. Term spelling is checked on the texts as written, capitals included.
    public static func score(sentence: CalibrationSentence, transcript: String, audioSeconds: TimeInterval,
                             processingSeconds: TimeInterval, glossaryTerms: [String]) -> CalibrationSentenceScore {
        let wer = alignment(reference: sentence.text, transcript: transcript)
        let terms = TermHitRate.evaluate(terms: TermHitRate.termList(glossaryTerms: glossaryTerms, reference: sentence.text),
                                         reference: sentence.text, hypothesis: transcript)
        return CalibrationSentenceScore(sentenceID: sentence.id, transcript: transcript, audioSeconds: audioSeconds,
                                        processingSeconds: processingSeconds, referenceWords: wer.referenceWordCount,
                                        wordErrors: wer.errors, termCount: terms.total, termHits: terms.hits)
    }
}

/// Which engine to use for this voice, and why.
public struct CalibrationRecommendation: Codable, Sendable, Hashable {
    public enum Verdict: String, Codable, Sendable, Hashable {
        /// Nothing was scored.
        case none
        /// Only one engine was ready, so there is nothing to compare it with.
        case onlyOne
        /// One engine got clearly more words right.
        case better
        /// Ordinary words came out about the same, but one engine got clearly more glossary terms right.
        case betterOnTerms
        /// Too close to call on accuracy and on terms.
        case aboutTheSame
    }

    public var verdict: Verdict
    /// The engine to use: the winner, the only engine, or (when they are about the same) the clearly faster one.
    /// Nil when there is nothing to choose between them.
    public var engine: EngineID?
    /// The engine it was compared with.
    public var other: EngineID?

    public init(verdict: Verdict, engine: EngineID? = nil, other: EngineID? = nil) {
        self.verdict = verdict
        self.engine = engine
        self.other = other
    }

    /// A gap in word accuracy smaller than this is "about the same". Ten sentences are about 150 words, so one
    /// word is two thirds of a point and the sampling error on each engine's score is around two points.
    public static let accuracyMargin = 0.03
    /// …and the engines must also differ by at least this many words, so a very short script can't produce a
    /// winner from one slip.
    public static let minimumWordDifference = 3
    /// Glossary terms: a clear difference is at least two more terms right and 15 points of hit rate.
    public static let termMargin = 0.15
    public static let minimumTermDifference = 2
    /// Speed is only mentioned (or used to break a tie) when one engine is at least this many times faster.
    public static let speedRatioWorthMentioning = 1.5

    /// The rule. With more than two engines, the two most accurate are compared.
    public static func decide(_ scores: [CalibrationEngineScore]) -> CalibrationRecommendation {
        let ranked = scores.filter { $0.referenceWords > 0 }.sorted { a, b in
            if a.wordAccuracy != b.wordAccuracy { return a.wordAccuracy > b.wordAccuracy }
            return (a.termHitRate ?? 0) > (b.termHitRate ?? 0)
        }
        guard let first = ranked.first else { return CalibrationRecommendation(verdict: .none) }
        guard ranked.count > 1 else { return CalibrationRecommendation(verdict: .onlyOne, engine: first.engine) }
        let second = ranked[1]

        let gap = first.wordAccuracy - second.wordAccuracy
        // Compare error counts on the same footing even if a sentence failed for one engine.
        let wordGap = Double(second.wordErrors) / Double(second.referenceWords) * Double(first.referenceWords)
            - Double(first.wordErrors)
        if gap >= accuracyMargin, wordGap >= Double(minimumWordDifference) {
            return CalibrationRecommendation(verdict: .better, engine: first.engine, other: second.engine)
        }

        if let a = first.termHitRate, let b = second.termHitRate {
            let (winner, loser) = a >= b ? (first, second) : (second, first)
            let rateGap = abs(a - b)
            let hitGap = abs(first.termHits - second.termHits)
            if rateGap >= termMargin, hitGap >= minimumTermDifference {
                return CalibrationRecommendation(verdict: .betterOnTerms, engine: winner.engine, other: loser.engine)
            }
        }

        // About the same: the clearly faster engine is the sensible one to use, if there is one.
        if let faster = fasterEngine(first, second) {
            let slower = faster.engine == first.engine ? second : first
            return CalibrationRecommendation(verdict: .aboutTheSame, engine: faster.engine, other: slower.engine)
        }
        return CalibrationRecommendation(verdict: .aboutTheSame, engine: nil, other: nil)
    }

    /// The engine that is at least `speedRatioWorthMentioning` times faster than the other, if either is.
    static func fasterEngine(_ a: CalibrationEngineScore, _ b: CalibrationEngineScore) -> CalibrationEngineScore? {
        guard let ratio = speedRatio(a, b) else { return nil }
        if ratio >= speedRatioWorthMentioning { return a }
        if ratio <= 1 / speedRatioWorthMentioning { return b }
        return nil
    }

    /// How many times faster `a` is than `b` (above 1 when `a` is faster).
    static func speedRatio(_ a: CalibrationEngineScore, _ b: CalibrationEngineScore) -> Double? {
        guard let sa = a.secondsPerMinute, let sb = b.secondsPerMinute, sa > 0, sb > 0 else { return nil }
        return sb / sa
    }

    // MARK: Wording

    /// "96%"
    public static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// "about twice as fast", "about four times faster".
    static func speedPhrase(_ ratio: Double) -> String {
        if ratio < 2.5 { return "about twice as fast" }
        let times = Int(ratio.rounded())
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return "about \(times < words.count ? words[times] : String(times)) times faster"
    }

    /// The recommendation in plain words, for the results screen and `devshout-cli calibrate`:
    /// "Whisper understood you better: 96% against 89%. Parakeet is about four times faster."
    /// - Parameter notCompared: engines that weren't ready, to say that they can be compared later.
    public func summary(scores: [CalibrationEngineScore], notCompared: [EngineID] = []) -> String {
        func score(_ id: EngineID?) -> CalibrationEngineScore? { scores.first { $0.engine == id } }
        func accuracy(_ id: EngineID?) -> String { Self.percent(score(id)?.wordAccuracy ?? 0) }

        switch verdict {
        case .none:
            return "Nothing could be measured. Try again, and check the input level moves while you read."
        case .onlyOne:
            guard let engine else { return "" }
            var text = "\(engine.shortName) got \(accuracy(engine)) of your words right."
            if let missing = notCompared.first {
                text += " Download \(missing.shortName) in Settings → Transcription and calibrate again to compare the two."
            }
            return text
        case .better:
            guard let engine, let other, let winner = score(engine), let loser = score(other) else { return "" }
            var text = "\(engine.shortName) understood you better: \(accuracy(engine)) of your words right against \(accuracy(other))."
            if let ratio = Self.speedRatio(loser, winner), ratio >= Self.speedRatioWorthMentioning {
                text += " \(other.shortName) is \(Self.speedPhrase(ratio))."
            } else if let ratio = Self.speedRatio(winner, loser), ratio >= Self.speedRatioWorthMentioning {
                text += " It is also \(Self.speedPhrase(ratio))."
            }
            return text
        case .betterOnTerms:
            guard let engine, let other, let winner = score(engine), let loser = score(other) else { return "" }
            return "Both got about the same share of ordinary words right (\(accuracy(engine)) and \(accuracy(other))), "
                + "but \(engine.shortName) got more of your glossary terms right: "
                + "\(winner.termHits) of \(winner.termCount) against \(loser.termHits) of \(loser.termCount)."
        case .aboutTheSame:
            let ranked = scores.sorted { $0.wordAccuracy > $1.wordAccuracy }
            guard ranked.count >= 2 else { return "" }
            var text = "\(ranked[0].engine.shortName) and \(ranked[1].engine.shortName) understood you about the same: "
                + "\(Self.percent(ranked[0].wordAccuracy)) and \(Self.percent(ranked[1].wordAccuracy)) of your words right. "
                + "A few sentences are a small sample, so a gap this small doesn't mean much."
            if let engine, let other, let fast = score(engine), let slow = score(other),
               let ratio = Self.speedRatio(fast, slow) {
                text += " \(engine.shortName) is \(Self.speedPhrase(ratio)), so it is the better choice."
            }
            return text
        }
    }
}
