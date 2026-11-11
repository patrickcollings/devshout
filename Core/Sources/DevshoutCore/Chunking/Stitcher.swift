import Foundation

/// Joins chunk transcripts into one raw transcript (PLAN §4.2).
///
/// - Chunks are put in `index` order (they may finish out of order) and empty ones are skipped.
/// - **Natural cuts** (no overlap): joined with one space. All whitespace is collapsed and the ends are trimmed;
///   casing and punctuation are left alone.
/// - **Forced cuts** (`overlapBefore` > 0, and the previous chunk really reaches into this one): the overlap is
///   heard twice, so it is deduplicated.
///   - With word timings on both sides, by time. The previous chunk drops its words starting at or after the middle
///     of the overlap (they sit against its cut, where a word may be clipped). This chunk then drops its leading
///     words that the previous chunk's **last kept word** already covers: those starting before the middle of that
///     word. This chunk is cut where the previous one really stops rather than at a fixed time, so a word the two
///     decodes time either side of the middle of the overlap is neither lost nor doubled. The two decodes' clocks
///     can disagree (a chunk's first words are placed less precisely): the difference is measured from the words
///     both wrote the same way and allowed for (`timingShift`). A word they wrote differently ("12%" and "twelve")
///     can't be matched as text in general, so it is dropped by time, or as the same number written two ways.
///   - Without timings, the longest run of up to `maxFallbackWords` words that ends the previous chunk and starts
///     this one is removed from the previous chunk. Words are compared ignoring case and punctuation, and a number
///     word equals its digits ("twelve" and "12%").
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
                    // The time rule keeps a word when in doubt (a duplicate is better than a lost word), so a copy
                    // of the last kept word can survive when the two decodes time it far apart. Glue only one
                    // utterance heard from both sides: the earlier copy still runs when the later one starts. A
                    // word really said twice ("very very") starts after the first copy ends.
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

    /// A word as the text rule compares it: `normalised`, with a number word as its digits, since an engine can
    /// write the same spoken number either way in two decodes ("twelve." and "12%" are both "12").
    static func comparable(_ text: String) -> String {
        let word = normalised(text)
        if let value = SpokenNumbers.units[word] ?? SpokenNumbers.teens[word] ?? SpokenNumbers.tens[word] {
            return String(value)
        }
        return word
    }

    // MARK: - Overlap

    /// How a forced seam was deduplicated.
    enum Dedupe: Equatable {
        /// By word timings.
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
            // Measured before anything is dropped: it needs the words both decodes heard.
            let shift = timingShift(previous: previous, next: next)
            previous.removeAll { $0.start! >= midpoint }
            // Nothing kept (the previous chunk only has words in the second half of the overlap): the next chunk
            // heard all of them, so it keeps everything.
            guard let last = previous.last, let lastStart = last.start else { return .timed }
            // A leading word of the next chunk is a second hearing of something already kept when it starts before
            // the middle of the last kept word; the word that follows starts around that word's end. The middle
            // leaves half the word's length for the two decodes to disagree by, in either direction.
            let lastEnd = max(last.end ?? lastStart, lastStart)
            let covered = (lastStart + lastEnd) / 2
            next.removeFirst(next.prefix { $0.start! - shift < covered }.count)
            // The same word written two ways ("12%." then "twelve.") that still overlaps the last kept word.
            if let first = next.first, first.start! - shift < lastEnd, !comparable(first.text).isEmpty,
               comparable(first.text) == comparable(last.text) {
                next.removeFirst()
            }
            return .timed
        }
        let longest = min(maxFallbackWords, previous.count, next.count)
        guard longest > 0 else { return .textUnmatched }
        for length in stride(from: longest, through: 1, by: -1) {
            let tail = previous.suffix(length).map { comparable($0.text) }
            let head = next.prefix(length).map { comparable($0.text) }
            if tail == head {
                previous.removeLast(length)
                return .textMatched
            }
        }
        return .textUnmatched
    }

    /// The largest difference between the two decodes' clocks that is believed.
    static let maxTimingShift: TimeInterval = 0.6
    /// How closely two shared words must agree on that difference to count as the same shift.
    static let timingShiftAgreement: TimeInterval = 0.15

    /// How much later the next chunk times the words both chunks heard (negative when earlier). An engine places
    /// words less precisely at the very start of a chunk, where it has no context: Parakeet has been seen putting
    /// the same words 0.28 s later in the next chunk than in the previous one, which is longer than a short word.
    ///
    /// Measured from the words at the seam that both decodes wrote the same way (a number word equals its
    /// digits), each paired with its nearest copy in time. One shared word is not enough: a copy that starts
    /// after the first one ended looks exactly like a word said twice ("very very"), which must survive. So the
    /// shift is believed only when at least two shared words agree on it, or when a single shared word's two
    /// copies overlap in time. Zero otherwise.
    static func timingShift(previous: [Token], next: [Token]) -> TimeInterval {
        let tail = previous.suffix(maxFallbackWords)
        var differences: [TimeInterval] = []
        var overlapping = false
        for word in next.prefix(maxFallbackWords) {
            let text = comparable(word.text)
            guard !text.isEmpty, let start = word.start else { continue }
            let nearest = tail
                .filter { comparable($0.text) == text && $0.start != nil }
                .min { abs(start - $0.start!) < abs(start - $1.start!) }
            guard let nearest, let nearestStart = nearest.start else { continue }
            let difference = start - nearestStart
            guard abs(difference) <= maxTimingShift else { continue }
            differences.append(difference)
            if start < (nearest.end ?? nearestStart) { overlapping = true }
        }
        let sorted = differences.sorted()
        guard let smallest = sorted.first, let largest = sorted.last else { return 0 }
        if sorted.count >= 2 {
            return largest - smallest <= timingShiftAgreement ? sorted[sorted.count / 2] : 0
        }
        return overlapping ? smallest : 0
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
