import Foundation
import Testing
@testable import DevshoutCore

/// A stitching case in `Fixtures/chunking/stitch/*.json`.
struct StitchFixture: Decodable {
    var description: String
    var expected: String
    var chunks: [ChunkTranscript]

    static let directory = "Fixtures/chunking/stitch"

    static func names() -> [String] {
        guard let root = Bundle.module.resourceURL?.appendingPathComponent(directory),
              let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return urls.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    static func load(_ name: String) throws -> StitchFixture {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: directory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(StitchFixture.self, from: Data(contentsOf: url))
    }
}

/// Chunk 0 covers 0–14.208 s; chunk 1 starts 1 s before that, so the midpoint of the overlap is 13.708 s.
private func forced(_ previous: String, _ next: String,
                    previousWords: [TimedWord]? = nil, nextWords: [TimedWord]? = nil) -> String {
    Stitcher.stitch([
        ChunkTranscript(index: 0, startSample: 0, endSample: 227_328, text: previous, words: previousWords,
                        engine: .parakeetV3, elapsed: 0),
        ChunkTranscript(index: 1, startSample: 211_328, endSample: 435_000, overlapBefore: 16_000, text: next,
                        words: nextWords, engine: .parakeetV3, elapsed: 0),
    ])
}

private func natural(_ texts: String...) -> String {
    Stitcher.stitch(texts.enumerated().map { index, text in
        ChunkTranscript(index: index, startSample: index * 100_000, endSample: index * 100_000 + 50_000, text: text,
                        engine: .whisperLargeV3Turbo, elapsed: 0)
    })
}

private func timed(_ words: [(String, TimeInterval)]) -> [TimedWord] {
    words.map { TimedWord(text: $0.0, start: $0.1, end: $0.1 + 0.1) }
}

@Suite struct StitcherTests {
    @Test func fixturesArePresent() {
        #expect(StitchFixture.names().count >= 10)
    }

    @Test(arguments: StitchFixture.names())
    func fixture(_ name: String) throws {
        let fixture = try StitchFixture.load(name)
        #expect(Stitcher.stitch(fixture.chunks) == fixture.expected, "\(name): \(fixture.description)")
        // Order of arrival never matters.
        #expect(Stitcher.stitch(fixture.chunks.reversed()) == fixture.expected, "\(name), reversed")
    }

    @Test func emptyInput() {
        #expect(Stitcher.stitch([]) == "")
        #expect(natural("", "  ", "\n") == "")
        #expect(natural("  one  ") == "one")
    }

    @Test func naturalCutsJoinWithOneSpace() {
        #expect(natural("Hello there.", "How are you?") == "Hello there. How are you?")
        #expect(natural("a\n\nb ", " c\td") == "a b c d")
        // Repeats across a natural cut are real speech and stay.
        #expect(natural("over and over", "over and over") == "over and over over and over")
    }

    @Test func fallbackRemovesTheLongestRepeat() {
        #expect(forced("one two three", "two three four") == "one two three four")
        #expect(forced("a b a b", "a b a b c") == "a b a b c")
        #expect(forced("We said yes", "Yes! Then we left.") == "We said Yes! Then we left.")
        // Nothing repeated: both kept whole.
        #expect(forced("the first part", "a second part") == "the first part a second part")
    }

    @Test func fallbackLooksAtEightWordsAtMost() {
        let eight = "one two three four five six seven eight"
        #expect(forced("start \(eight)", "\(eight) end") == "start \(eight) end")
        let nine = "one two three four five six seven eight nine"
        #expect(forced("start \(nine)", "\(nine) end") == "start \(nine) \(nine) end")
    }

    @Test func midpointRule() {
        let previous = timed([("we", 12.0), ("ship", 13.0), ("it", 13.4), ("now", 13.708)])
        let next = timed([("it", 13.45), ("now", 13.708), ("please", 14.0)])
        // A word starting exactly at the midpoint belongs to the next chunk.
        #expect(forced("we ship it now", "it now please", previousWords: previous, nextWords: next)
            == "we ship it now please")
    }

    @Test func midpointNeedsTimingsOnBothSides() {
        let previous = timed([("one", 12.0), ("two", 13.0), ("three", 13.9)])
        // The next chunk has none, so the text rule runs instead.
        #expect(forced("one two three", "two three four", previousWords: previous) == "one two three four")
    }

    @Test func timingsThatDoNotSpellTheTextAreIgnored() {
        let previous = timed([("one", 12.0), ("too", 13.0), ("three", 13.9)])
        let next = timed([("two", 13.3), ("three", 13.9), ("four", 14.2)])
        #expect(forced("one two three", "two three four", previousWords: previous, nextWords: next)
            == "one two three four")
    }

    @Test func overlapOnlyCountsWhenTheChunksMeet() {
        // Chunk 1 is missing (the engine failed): chunk 2's overlap was with it, not with chunk 0.
        let chunks = [
            ChunkTranscript(index: 0, startSample: 0, endSample: 200_000, text: "one two", engine: .parakeetV3,
                            elapsed: 0),
            ChunkTranscript(index: 2, startSample: 400_000, endSample: 600_000, overlapBefore: 16_000,
                            text: "two three", engine: .parakeetV3, elapsed: 0),
        ]
        #expect(Stitcher.stitch(chunks) == "one two two three")
    }

    @Test func gluedWords() {
        #expect(forced("it works", "rks fine") == "it works fine")
        #expect(forced("an organ", "organisation chart") == "an organisation chart")
        #expect(forced("it does work", "orks now") == "it does works now")
        // Without timings the text rule gets there first, keeping the next chunk's copy.
        #expect(forced("before the meeting,", "Meeting starts") == "before the Meeting starts")
    }

    @Test func gluingKeepsOuterPunctuation() {
        var previous = [Stitcher.Token(text: "(quote", start: 1)]
        var next = [Stitcher.Token(text: "Quote),", start: 2), Stitcher.Token(text: "done", start: 3)]
        Stitcher.glue(&previous, &next)
        #expect(previous == [Stitcher.Token(text: "(quote),", start: 1)])
        #expect(next.map(\.text) == ["done"])
    }

    @Test func wordsSaidTwiceSurviveTheSeam() {
        // Timed: the second "very" starts after the first ends, so both stay.
        let previous = [TimedWord(text: "it", start: 12.8, end: 12.9), TimedWord(text: "was", start: 13.0, end: 13.2),
                        TimedWord(text: "very", start: 13.3, end: 13.6)]
        let next = [TimedWord(text: "very", start: 13.75, end: 14.1), TimedWord(text: "good", start: 14.2, end: 14.5)]
        #expect(forced("it was very", "very good", previousWords: previous, nextWords: next)
            == "it was very very good")
        let had = [TimedWord(text: "I", start: 13.0, end: 13.1), TimedWord(text: "had", start: 13.2, end: 13.5)]
        let hadNext = [TimedWord(text: "had", start: 13.8, end: 14.0), TimedWord(text: "enough", start: 14.1, end: 14.5)]
        #expect(forced("I had", "had enough", previousWords: had, nextWords: hadNext) == "I had had enough")
        // Untimed: the text rule removes the one heard twice and keeps the repeat.
        #expect(forced("it was very very", "very good") == "it was very very good")
        // Timed but overlapping in time: one word heard from both sides.
        let cut = [TimedWord(text: "it", start: 13.0, end: 13.2), TimedWord(text: "works", start: 13.4, end: 13.8)]
        let cutNext = [TimedWord(text: "rks", start: 13.72, end: 13.8), TimedWord(text: "fine", start: 13.9, end: 14.2)]
        #expect(forced("it works", "rks fine", previousWords: cut, nextWords: cutNext) == "it works fine")
    }

    @Test func shortWordsAreNotGlued() {
        #expect(forced("and this", "is it") == "and this is it")
        #expect(forced("we need the", "theory now") == "we need the theory now")
        #expect(forced("a long action", "on it") == "a long action on it")
    }

    @Test func gluingKeepsUnrelatedWords() {
        #expect(forced("one two", "three four") == "one two three four")
    }

    @Test func midpointCanEmptyAChunk() {
        // Everything the next chunk heard was before the midpoint and is already in the previous one.
        let previous = timed([("so", 12.0), ("yes", 13.2)])
        let next = timed([("yes", 13.25)])
        #expect(forced("so yes", "yes", previousWords: previous, nextWords: next) == "so yes")
    }

    @Test func tokenTimingAlignment() {
        let transcript = ChunkTranscript(
            index: 0, startSample: 0, endSample: 64_000, text: "Hello, world — it's AB-1234.",
            words: timed([("▁Hel", 0.1), ("lo", 0.2), (",", 0.3), ("▁world", 0.5), ("▁it", 1.0), ("'s", 1.1),
                          ("▁AB", 1.5), ("-", 1.6), ("1234", 1.7), (".", 2.0)]),
            engine: .parakeetV3, elapsed: 0)
        let tokens = Stitcher.tokenize(transcript)
        #expect(tokens.map(\.text) == ["Hello,", "world", "—", "it's", "AB-1234."])
        #expect(tokens.map(\.start) == [0.1, 0.5, 0.5, 1.0, 1.5])
        // An end comes from the timed word holding the last letter or digit ("1234", not ".").
        let ends = tokens.compactMap(\.end)
        #expect(ends.count == 5)
        #expect(zip(ends, [0.3, 0.6, 0.6, 1.2, 1.8]).allSatisfy { abs($0 - $1) < 1e-9 })
    }
}
