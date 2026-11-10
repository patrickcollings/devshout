import Foundation

/// Joins chunk transcripts into one raw transcript (PLAN §4.2).
///
/// - Chunks are put in `index` order (they may finish out of order) and empty ones are skipped.
/// - **Natural cuts** (no overlap): joined with one space. All whitespace is collapsed and the ends are trimmed;
///   casing and punctuation are left alone.
/// - **Forced cuts** (`overlapBefore` > 0, and the previous chunk really reaches into this one): the overlap is
///   heard twice, so it is deduplicated. With word timings on both sides, the **midpoint rule**: words of the
///   previous chunk starting at or after the middle of the overlap are dropped, and so are words of this chunk
///   starting before it. Without timings, the longest run of up to `maxFallbackWords` words that ends the previous
///   chunk and starts this one (ignoring case and punctuation) is removed from the previous chunk.
/// - **Glued words** at a forced seam: when the last word of the previous chunk and the first word of this one
///   overlap as strings ("meeting" + "Meeting", "works" + "rks", "organ" + "organisation", "work" + "orks"), one
///   copy is kept. With timings, only when the two copies overlap in time (one utterance heard from both sides);
///   a word said twice ("very very", "had had") starts after the first copy ends and stays. Without timings, only
///   when the text rule found no repeat (if it did, the seam is already settled). Natural cuts are never glued.
///
/// Word timings are read from `ChunkTranscript.words` (seconds from the start of the recording). They may be whole
/// words or sub-word tokens: they are matched to the words of `text` by their letters and digits. When they don't
/// match `text`, or lie outside the chunk, they are ignored and the text rule is used.
public enum Stitcher {
    /// The longest repeated run the no-timings fallback removes.
    public static let maxFallbackWords = 8
    /// The shortest partial word the glued-word rule merges. Shorter fragments are too often real words ("this is",
    /// "action on"). A partial word at the start of the next one must be one letter longer, because short words
    /// so often begin longer ones ("the theory", "for format").
    public static let minGlueFragment = 3

    public static func stitch(_ transcripts: [ChunkTranscript]) -> String {
        let ordered = transcripts.enumerated()
            .sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }
            .map(\.element)

        var pieces: [[Token]] = []
        var previous: ChunkTranscript?
        for transcript in ordered {
            var tokens = tokenize(transcript)
            guard !tokens.isEmpty else { continue }
            if let previous, var previousTokens = pieces.last, transcript.overlapBefore > 0,
               previous.endSample > transcript.startSample {
                let overlapEnd = min(previous.endSample, transcript.startSample + transcript.overlapBefore)
                let midpoint = Double(transcript.startSample + overlapEnd) / 2 / Double(AudioFormat.sampleRate)
                switch deduplicate(&previousTokens, &tokens, midpoint: midpoint) {
                case .timed:
                    // Glue only one utterance heard from both sides: the earlier copy still runs when the later one
                    // starts. A word really said twice ("very very") starts after the first copy ends.
                    if let last = previousTokens.last?.end, let first = tokens.first?.start, last > first {
                        glue(&previousTokens, &tokens)
                    }
                case .textUnmatched:
                    glue(&previousTokens, &tokens)
                case .textMatched:
                    break // the repeat is already gone; equal words left at the seam were said twice
                }
                pieces[pieces.count - 1] = previousTokens
            }
            guard !tokens.isEmpty else { continue }
            pieces.append(tokens)
            previous = transcript
        }
        return pieces.joined().map(\.text).joined(separator: " ")
    }

    // MARK: - Tokens

    struct Token: Equatable {
        var text: String
        /// Seconds from the start of the recording, when the chunk had usable timings.
        var start: TimeInterval?
        var end: TimeInterval?

        init(text: String, start: TimeInterval? = nil, end: TimeInterval? = nil) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// Splits a chunk's text on whitespace and gives each word the start time of its first letter or digit and the
    /// end time of its last.
    static func tokenize(_ transcript: ChunkTranscript) -> [Token] {
        let words = transcript.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        guard let times = alignTimings(words: words, timed: transcript.words ?? [], transcript: transcript) else {
            return words.map { Token(text: $0) }
        }
        return zip(words, times).map { Token(text: $0, start: $1.start, end: $1.end) }
    }

    /// Start and end times for `words`, or nil when the timings are missing, don't spell the same text, or lie outside
    /// the chunk (for instance timings relative to the chunk rather than the recording).
    static func alignTimings(words: [String], timed: [TimedWord],
                             transcript: ChunkTranscript) -> [(start: TimeInterval, end: TimeInterval)]? {
        guard !timed.isEmpty else { return nil }
        let rate = Double(AudioFormat.sampleRate)
        let tolerance = 0.5
        let chunkStart = Double(transcript.startSample) / rate - tolerance
        let chunkEnd = Double(transcript.endSample) / rate + tolerance
        guard timed.allSatisfy({ $0.start >= chunkStart && $0.start <= chunkEnd }) else { return nil }

        // Each letter or digit of the timings, with the timed word it belongs to.
        var timedCharacters: [Character] = []
        var owners: [TimedWord] = []
        for word in timed {
            for character in normalisedCharacters(word.text) {
                timedCharacters.append(character)
                owners.append(word)
            }
        }

        var times: [(start: TimeInterval, end: TimeInterval)] = []
        var position = 0
        for word in words {
            let characters = normalisedCharacters(word)
            if characters.isEmpty {
                // Punctuation on its own ("—"): it goes with the word before it.
                times.append(times.last ?? (timed[0].start, timed[0].start))
                continue
            }
            let end = position + characters.count
            guard end <= timedCharacters.count, Array(timedCharacters[position..<end]) == characters else {
                return nil
            }
            times.append((owners[position].start, owners[end - 1].end))
            position = end
        }
        return position == timedCharacters.count ? times : nil
    }

    /// Lower-cased letters and digits, one string per character so lower-casing can't shift positions.
    static func normalisedCharacters(_ text: String) -> [Character] {
        text.compactMap { character -> Character? in
            guard character.isLetter || character.isNumber else { return nil }
            return String(character).lowercased().first ?? character
        }
    }

    static func normalised(_ text: String) -> String { String(normalisedCharacters(text)) }

    // MARK: - Overlap

    /// How a forced seam was deduplicated.
    enum Dedupe: Equatable {
        /// By the midpoint rule.
        case timed
        /// By the text rule, which removed a repeated run.
        case textMatched
        /// By the text rule, which found nothing repeated.
        case textUnmatched
    }

    @discardableResult
    static func deduplicate(_ previous: inout [Token], _ next: inout [Token], midpoint: TimeInterval) -> Dedupe {
        let timed = previous.allSatisfy { $0.start != nil } && next.allSatisfy { $0.start != nil }
        if timed {
            previous.removeAll { $0.start! >= midpoint }
            next.removeAll { $0.start! < midpoint }
            return .timed
        }
        let longest = min(maxFallbackWords, previous.count, next.count)
        guard longest > 0 else { return .textUnmatched }
        for length in stride(from: longest, through: 1, by: -1) {
            let tail = previous.suffix(length).map { normalised($0.text) }
            let head = next.prefix(length).map { normalised($0.text) }
            if tail == head {
                previous.removeLast(length)
                return .textMatched
            }
        }
        return .textUnmatched
    }

    /// Merges the words either side of a forced seam when they overlap as strings.
    static func glue(_ previous: inout [Token], _ next: inout [Token]) {
        guard let last = previous.last, let first = next.first else { return }
        let a = split(last.text)
        let b = split(first.text)
        let lowerA = a.core.map(lowercased)
        let lowerB = b.core.map(lowercased)
        guard !lowerA.isEmpty, !lowerB.isEmpty else { return }

        let overlap: Int
        if lowerA == lowerB {
            overlap = lowerB.count
        } else if lowerB.count >= minGlueFragment, lowerA.count > lowerB.count,
                  Array(lowerA.suffix(lowerB.count)) == lowerB {
            overlap = lowerB.count // "works" + "rks": the next word is the end of the previous one
        } else if lowerA.count > minGlueFragment, lowerB.count > lowerA.count,
                  Array(lowerB.prefix(lowerA.count)) == lowerA {
            overlap = lowerA.count // "organ" + "organisation": the previous word is the start of the next one
        } else {
            var found = 0
            let longest = min(lowerA.count, lowerB.count) - 1
            if longest >= minGlueFragment {
                for length in stride(from: longest, through: minGlueFragment, by: -1)
                where Array(lowerA.suffix(length)) == Array(lowerB.prefix(length)) {
                    found = length
                    break
                }
            }
            guard found > 0 else { return }
            overlap = found // "work" + "orks"
        }
        let merged = a.leading + String(a.core) + String(b.core.dropFirst(overlap)) + b.trailing
        previous[previous.count - 1] = Token(text: merged, start: last.start, end: first.end)
        next.removeFirst()
    }

    private static func lowercased(_ character: Character) -> String { String(character).lowercased() }

    /// A word as leading punctuation, its core (from the first to the last letter or digit) and trailing punctuation.
    private static func split(_ word: String) -> (leading: String, core: [Character], trailing: String) {
        let characters = Array(word)
        guard let first = characters.firstIndex(where: { $0.isLetter || $0.isNumber }),
              let last = characters.lastIndex(where: { $0.isLetter || $0.isNumber }) else {
            return (word, [], "")
        }
        return (String(characters[..<first]), Array(characters[first...last]), String(characters[(last + 1)...]))
    }
}
