import Foundation

// What calibration learns about a speaker from the word alignment of each sentence against its transcript:
// - glossary terms that came out as something else ("causia" for CORSIA): offered as `heard:` forms, which the
//   `TextFixer` then replaces in every mode;
// - ordinary words that came out as other ordinary words ("walk" for "work"): never replaced blindly, only offered
//   as a note for the glossary's Style section, which Claude reads in Tidy and Structure.

/// A glossary term an engine wrote as something else.
public struct LearnedCorrection: Codable, Sendable, Hashable, Identifiable {
    /// The glossary entry's term, as spelled in the glossary.
    public var term: String
    /// What was written instead, in lower case ("core sea").
    public var heard: String
    /// The engines that wrote it, in `EngineID.allCases` order.
    public var engines: [EngineID]
    /// How many times, over all engines and sentences.
    public var count: Int
    /// Every word of `heard` is an ordinary English word (or a number), so replacing it everywhere would also
    /// rewrite sentences where the speaker really said it ("component" for "proponent"). Not ticked by default.
    public var isOrdinaryPhrase: Bool

    public init(term: String, heard: String, engines: [EngineID], count: Int, isOrdinaryPhrase: Bool) {
        self.term = term
        self.heard = heard
        self.engines = engines
        self.count = count
        self.isOrdinaryPhrase = isOrdinaryPhrase
    }

    public var id: String { term + "\u{1F}" + heard }
    /// Whether the correction is ticked before the user looks at it.
    public var isSuggested: Bool { !isOrdinaryPhrase }
}

/// An ordinary word that was written as another word.
public struct LearnedStyleNote: Codable, Sendable, Hashable, Identifiable {
    /// The word in the sentence the speaker read.
    public var said: String
    /// The word the engine wrote.
    public var written: String
    public var engines: [EngineID]
    public var count: Int

    public init(said: String, written: String, engines: [EngineID], count: Int) {
        self.said = said
        self.written = written
        self.engines = engines
        self.count = count
    }

    public var id: String { said + "\u{1F}" + written }

    /// The line added to the glossary's Style section.
    public var text: String {
        "This speaker's dictation often writes \"\(written)\" where they said \"\(said)\"; use the context to decide which is meant."
    }
}

public enum CalibrationLearning {
    /// One engine's transcript of one sentence.
    public struct Observation: Sendable, Hashable {
        public var engine: EngineID
        public var sentence: CalibrationSentence
        public var transcript: String

        public init(engine: EngineID, sentence: CalibrationSentence, transcript: String) {
            self.engine = engine
            self.sentence = sentence
            self.transcript = transcript
        }
    }

    /// At most this many style notes are offered: the most frequent.
    public static let styleNoteLimit = 3
    /// A mishearing longer than the term by more than this many words is taken to be noise, not a mishearing.
    static let extraWordsAllowed = 3

    /// One step of the alignment with its position in the reference.
    private struct Step {
        var kind: AlignedWord.Kind
        /// Index of the reference word (for an insertion: the reference word it comes before).
        var referenceIndex: Int
        var hypothesis: String?
        var reference: String?
    }

    private static func steps(_ alignment: [AlignedWord]) -> [Step] {
        var out: [Step] = []
        var referenceIndex = 0
        for word in alignment {
            out.append(Step(kind: word.kind, referenceIndex: referenceIndex, hypothesis: word.hypothesis, reference: word.reference))
            if word.kind != .insertion { referenceIndex += 1 }
        }
        return out
    }

    /// Where the glossary's terms are in the reference words: longest terms first, never overlapping.
    private static func termSpans(in words: [String], entries: [GlossaryEntry]) -> [(range: Range<Int>, entry: GlossaryEntry)] {
        let candidates = entries.map { (entry: $0, words: CalibrationText.words($0.term)) }
            .filter { !$0.words.isEmpty }
            .sorted { $0.words.count > $1.words.count }
        var taken = Set<Int>()
        var spans: [(range: Range<Int>, entry: GlossaryEntry)] = []
        for candidate in candidates {
            let length = candidate.words.count
            guard words.count >= length else { continue }
            var start = 0
            while start + length <= words.count {
                let range = start..<(start + length)
                if Array(words[range]) == candidate.words, !range.contains(where: { taken.contains($0) }) {
                    spans.append((range, candidate.entry))
                    range.forEach { taken.insert($0) }
                    start += length
                } else {
                    start += 1
                }
            }
        }
        return spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func entries(_ glossary: Glossary) -> [GlossaryEntry] {
        glossary.allEntries.map(\.entry).filter { !$0.isPattern }
    }

    /// Every word the engines wrote, as `corrections` will see them: what to ask the spelling checker about before
    /// calling it (the checker lives on the main thread; `corrections` takes a plain predicate).
    public static func transcriptWords(_ observations: [Observation]) -> Set<String> {
        Set(observations.flatMap { CalibrationText.words($0.transcript) })
    }

    /// Glossary terms that were written as something else, most frequent first.
    ///
    /// For each term in a sentence, the words the transcript has in its place are read off the alignment: the words
    /// aligned with the term's own words, plus words inserted inside it or right beside it (so CORSIA → "core sea"
    /// is found whichever of the two words the alignment paired with it). Nothing is offered when the term came out
    /// right, when it was dropped altogether, when the form is already a `heard:` of that entry, or when the form is
    /// itself another glossary term. A difference of capitals alone is not a mishearing the `TextFixer` can fix, so it
    /// is left to Claude.
    ///
    /// - Parameter isOrdinaryWord: whether a lower-case word is an ordinary English word (the Mac's spelling
    ///   checker in the app). Numbers and single letters always count as ordinary.
    public static func corrections(observations: [Observation], glossary: Glossary,
                                   isOrdinaryWord: (String) -> Bool) -> [LearnedCorrection] {
        let entries = entries(glossary)
        let termKeys = Set(entries.map { CalibrationText.words($0.term).joined(separator: " ") })
        var found: [String: (correction: LearnedCorrection, engines: Set<EngineID>, order: Int)] = [:]

        for observation in observations {
            let referenceWords = CalibrationText.words(observation.sentence.text)
            let spans = termSpans(in: referenceWords, entries: entries)
            guard !spans.isEmpty else { continue }
            let alignment = CalibrationScorer.alignment(reference: observation.sentence.text, transcript: observation.transcript)
            let steps = steps(alignment.alignment)

            for span in spans {
                let own = steps.filter { $0.kind != .insertion && span.range.contains($0.referenceIndex) }
                guard own.contains(where: { $0.kind != .match }) else { continue }
                // Insertions before the first word of the term, inside it, and after its last word.
                let heardWords = steps.compactMap { step -> String? in
                    switch step.kind {
                    case .insertion:
                        return (span.range.lowerBound...span.range.upperBound).contains(step.referenceIndex) ? step.hypothesis : nil
                    case .match, .substitution:
                        return span.range.contains(step.referenceIndex) ? step.hypothesis : nil
                    case .deletion:
                        return nil
                    }
                }
                let termWords = Array(referenceWords[span.range])
                guard !heardWords.isEmpty, heardWords.count <= termWords.count + extraWordsAllowed,
                      own.contains(where: { $0.kind != .deletion }) else { continue }
                let heard = heardWords.joined(separator: " ")
                guard heard != termWords.joined(separator: " "), !termKeys.contains(heard) else { continue }
                let known = span.entry.heard.map { CalibrationText.words($0).joined(separator: " ") }
                guard !known.contains(heard) else { continue }

                let ordinary = heardWords.allSatisfy { word in
                    CalibrationText.isNumeric(word) || word.count == 1 || isOrdinaryWord(word)
                }
                let key = span.entry.term + "\u{1F}" + heard
                if var existing = found[key] {
                    existing.correction.count += 1
                    existing.engines.insert(observation.engine)
                    found[key] = existing
                } else {
                    found[key] = (LearnedCorrection(term: span.entry.term, heard: heard, engines: [], count: 1,
                                                    isOrdinaryPhrase: ordinary), [observation.engine], found.count)
                }
            }
        }

        return found.values
            .sorted { a, b in
                if a.correction.count != b.correction.count { return a.correction.count > b.correction.count }
                return a.order < b.order
            }
            .map { item in
                var correction = item.correction
                correction.engines = EngineID.allCases.filter { item.engines.contains($0) }
                return correction
            }
    }

    /// Ordinary words written as other words, most frequent first, at most `limit`.
    ///
    /// Only clean, single-word swaps count: the words on both sides of the swap must have been understood, neither
    /// word may be a number or shorter than three letters, and a spelling variant (-ise and -ize) is not a
    /// mishearing. With two engines a swap must be seen at least twice (twice by one, or once by each), which keeps
    /// one engine's one-off slip out; with one engine every swap is offered.
    public static func styleNotes(observations: [Observation], glossary: Glossary,
                                  limit: Int = styleNoteLimit) -> [LearnedStyleNote] {
        let entries = entries(glossary)
        let engineCount = Set(observations.map(\.engine)).count
        let minimum = engineCount >= 2 ? 2 : 1
        var found: [String: (note: LearnedStyleNote, engines: Set<EngineID>, order: Int)] = [:]

        for observation in observations {
            let referenceWords = CalibrationText.words(observation.sentence.text)
            let inTerm = Set(termSpans(in: referenceWords, entries: entries).flatMap { Array($0.range) })
            let steps = steps(CalibrationScorer.alignment(reference: observation.sentence.text,
                                                          transcript: observation.transcript).alignment)
            for (index, step) in steps.enumerated() where step.kind == .substitution {
                guard !inTerm.contains(step.referenceIndex), let said = step.reference, let written = step.hypothesis else { continue }
                let before = index > 0 ? steps[index - 1].kind : .match
                let after = index + 1 < steps.count ? steps[index + 1].kind : .match
                guard before == .match, after == .match, isWorthNoting(said: said, written: written) else { continue }
                let key = said + "\u{1F}" + written
                if var existing = found[key] {
                    existing.note.count += 1
                    existing.engines.insert(observation.engine)
                    found[key] = existing
                } else {
                    found[key] = (LearnedStyleNote(said: said, written: written, engines: [], count: 1),
                                  [observation.engine], found.count)
                }
            }
        }

        return found.values
            .filter { $0.note.count >= minimum }
            .sorted { a, b in
                if a.note.count != b.note.count { return a.note.count > b.note.count }
                return a.order < b.order
            }
            .prefix(max(0, limit))
            .map { item in
                var note = item.note
                note.engines = EngineID.allCases.filter { item.engines.contains($0) }
                return note
            }
    }

    static func isWorthNoting(said: String, written: String) -> Bool {
        guard said.count >= 3, written.count >= 3 else { return false }
        guard !CalibrationText.isNumeric(said), !CalibrationText.isNumeric(written) else { return false }
        // "organise" and "organize" are the same word.
        if said.replacingOccurrences(of: "z", with: "s") == written.replacingOccurrences(of: "z", with: "s") { return false }
        return true
    }
}
