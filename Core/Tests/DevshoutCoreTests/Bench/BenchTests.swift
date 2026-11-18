import Foundation
import Testing
@testable import DevshoutCore

/// The repository's real `bench/` folder, found from this file's path (Core/Tests/DevshoutCoreTests/Bench/…).
private let benchDirectory: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("bench")
}()

@Suite struct BenchTextTests {
    @Test func lowercasesAndStripsPunctuation() {
        #expect(BenchText.normalise("Hello, World!") == "hello world")
        #expect(BenchText.normalise("  Hello,\n\tWorld  ") == "hello world")
        #expect(BenchText.normalise("") == "")
        #expect(BenchText.normalise("?!…") == "")
    }

    @Test func curlyQuotesAndDashes() {
        #expect(BenchText.normalise("Don’t stop — it’s “fine” – really") == "don't stop it's fine really")
        #expect(BenchText.normalise("‘quoted’") == "quoted")
        #expect(BenchText.normalise("well-known") == "well known")
    }

    @Test func numbersAndTickets() {
        #expect(BenchText.normalise("AB-1234,") == "ab 1234")
        #expect(BenchText.normalise("It is 3.5% of 1,000.") == "it is 3.5 of 1000")
        #expect(BenchText.normalise("20%") == "20")
        #expect(BenchText.normalise("1, 2, 3") == "1 2 3")
        #expect(BenchText.normalise("12,34") == "12 34")
    }

    @Test func accentsSurviveAndAreComposed() {
        #expect(BenchText.normalise("Siobha\u{301}n") == "siobhán")
        #expect(BenchText.normalise("Siobhán") == "siobhán")
    }
}

@Suite struct WordErrorRateTests {
    @Test func identicalTextsAfterNormalisation() {
        let result = WordErrorRate.compute(reference: "Check the CORSIA flag.", hypothesis: "check the corsia flag")
        #expect(result.wer == 0)
        #expect(result.errors == 0)
        #expect(result.hits == 4)
    }

    @Test func substitutionAndDeletion() {
        // ref: the cat sat on the mat (6)   hyp: the cat sit on mat
        // sat→sit is one substitution; the second "the" is deleted: 2 errors of 6.
        let result = WordErrorRate.compute(reference: "the cat sat on the mat", hypothesis: "the cat sit on mat")
        #expect(result.substitutions == 1)
        #expect(result.deletions == 1)
        #expect(result.insertions == 0)
        #expect(result.referenceWordCount == 6)
        #expect(abs(result.wer - 2.0 / 6.0) < 1e-12)
        #expect(result.errorSummary() == "~ sat → sit\n- the")
    }

    @Test func insertion() {
        let result = WordErrorRate.compute(reference: "hello world", hypothesis: "hello big world")
        #expect(result.insertions == 1)
        #expect(result.errors == 1)
        #expect(result.wer == 0.5)
        #expect(result.errorSummary() == "+ big")
    }

    @Test func emptyHypothesisIsAllDeletions() {
        let result = WordErrorRate.compute(reference: "one two three", hypothesis: "")
        #expect(result.deletions == 3)
        #expect(result.wer == 1)
    }

    @Test func emptyReference() {
        #expect(WordErrorRate.compute(reference: "", hypothesis: "").wer == 0)
        let result = WordErrorRate.compute(reference: "", hypothesis: "um er")
        #expect(result.insertions == 2)
        #expect(result.wer == 2)
    }

    @Test func mishearingCountsPerWord() {
        // "core sea" for "CORSIA": one substitution plus one insertion against a 6-word reference.
        let result = WordErrorRate.compute(reference: "check the CORSIA flag is set", hypothesis: "check the core sea flag is set")
        #expect(result.substitutions == 1)
        #expect(result.insertions == 1)
        #expect(result.referenceWordCount == 6)
        #expect(abs(result.wer - 2.0 / 6.0) < 1e-12)
    }

    @Test func totallyDifferentTexts() {
        // Three substitutions, no matches: 3 / 3.
        let result = WordErrorRate.compute(reference: "a b c", hypothesis: "x y z")
        #expect(result.substitutions == 3)
        #expect(result.wer == 1)
    }

    @Test func werCanExceedOne() {
        let result = WordErrorRate.compute(reference: "go", hypothesis: "please go now")
        #expect(result.insertions == 2)
        #expect(result.wer == 2)
    }

    @Test func alignmentOrderAndRows() {
        let result = WordErrorRate.compute(reference: "the cat sat", hypothesis: "the hat sat down")
        #expect(result.alignment.map(\.kind) == [.match, .substitution, .match, .insertion])
        #expect(result.alignment[1] == AlignedWord(kind: .substitution, reference: "cat", hypothesis: "hat"))
        #expect(result.alignedRows() == "REF: the CAT sat ***\nHYP: the HAT sat DOWN")
    }

    @Test func errorSummaryLimit() {
        let result = WordErrorRate.compute(reference: "a b c d", hypothesis: "w x y z")
        #expect(result.errorSummary(limit: 2) == "~ a → w\n~ b → x\n… and 2 more")
    }

    @Test func alignedRowsWrap() {
        let words = (1...30).map { "word\($0)" }.joined(separator: " ")
        let rows = WordErrorRate.compute(reference: words, hypothesis: words).alignedRows(width: 40)
        #expect(rows.contains("\n\n"))
        for line in rows.split(separator: "\n") where !line.isEmpty { #expect(line.count <= 45) }
    }
}

@Suite struct TermHitRateTests {
    let terms = ["CORSIA", "My Supply", "AB-1234", "NDC", "proponent"]

    @Test func exactSpellingIsAHit() {
        let result = TermHitRate.evaluate(
            terms: terms,
            reference: "Check the CORSIA flag on AB-1234 in My Supply.",
            hypothesis: "check the CORSIA flag on AB-1234 in My Supply")
        #expect(result.total == 3)
        #expect(result.hits == 3)
        #expect(result.rate == 1)
        #expect(result.missed.isEmpty)
    }

    @Test func termsAbsentFromTheReferenceAreIgnored() {
        let result = TermHitRate.evaluate(terms: terms, reference: "Nothing to see here", hypothesis: "CORSIA CORSIA")
        #expect(result.terms.isEmpty)
        #expect(result.total == 0)
        #expect(result.rate == nil)
    }

    @Test func caseSensitive() {
        let result = TermHitRate.evaluate(terms: terms, reference: "Check CORSIA and My Supply.",
                                          hypothesis: "Check corsia and my supply.")
        #expect(result.hits == 0)
        #expect(result.total == 2)
        #expect(result.rate == 0)
        #expect(result.missed.map(\.term) == ["CORSIA", "My Supply"])
    }

    @Test func partialHits() {
        // Reference has CORSIA, My Supply, AB-1234; the hypothesis gets two of them.
        let result = TermHitRate.evaluate(
            terms: terms,
            reference: "CORSIA in My Supply for AB-1234",
            hypothesis: "core sea in My Supply for AB-1234")
        #expect(result.hits == 2)
        #expect(result.total == 3)
        #expect(abs(result.rate! - 2.0 / 3.0) < 1e-12)
    }

    @Test func wholeWordsOnly() {
        // "NDC" is not found inside "NDCs"; "AB-123" is not found inside "AB-1234".
        let a = TermHitRate.evaluate(terms: ["NDC"], reference: "NDC", hypothesis: "the NDCs")
        #expect(a.hits == 0)
        let b = TermHitRate.evaluate(terms: ["AB-123"], reference: "AB-123", hypothesis: "AB-1234")
        #expect(b.hits == 0)
        let c = TermHitRate.evaluate(terms: ["NDC"], reference: "NDC", hypothesis: "(NDC), done")
        #expect(c.hits == 1)
    }

    @Test func repeatedOccurrencesCountEach() {
        let result = TermHitRate.evaluate(terms: ["NDC"], reference: "NDC and NDC again",
                                          hypothesis: "NDC and N D C again")
        #expect(result.total == 2)
        #expect(result.hits == 1)
        #expect(result.terms[0].isHit == false)
        // Extra occurrences in the hypothesis never push the score above the reference.
        let more = TermHitRate.evaluate(terms: ["NDC"], reference: "NDC", hypothesis: "NDC NDC NDC")
        #expect(more.hits == 1)
        #expect(more.rate == 1)
    }

    @Test func whitespaceAndQuotesAreForgiving() {
        let result = TermHitRate.evaluate(terms: ["My Supply", "it's"], reference: "My Supply it’s",
                                          hypothesis: "My\n  Supply it's")
        #expect(result.hits == 2)
    }

    @Test func duplicateAndEmptyTermsAreIgnored() {
        let result = TermHitRate.evaluate(terms: ["NDC", " NDC ", "", "  "], reference: "NDC", hypothesis: "NDC")
        #expect(result.terms.count == 1)
        #expect(result.total == 1)
    }

    @Test func ticketIDs() {
        #expect(TermHitRate.ticketIDs(in: "Move AB-987 and AB-2210, then AB-987 again; not xAB-1 or ab-5 or A-1.") == ["AB-987", "AB-2210"])
        let list = TermHitRate.termList(glossaryTerms: ["CORSIA", "AB-987"], reference: "AB-987 and AB-2210")
        #expect(list == ["CORSIA", "AB-987", "AB-2210"])
    }

    @Test func glossaryTermsFromMarkdown() {
        let markdown = """
        # Glossary
        ## Terms
        - !**CORSIA** — Carbon Offsetting
          - heard: **not** a term
        - **My Supply** — a product
        - **proponent**
        ## People
        - **Siobhán Murphy** — heard: shiv on
        ## Patterns
        - **AB-{n}** — Linear ticket IDs
        ## Style
        - **Bold** style notes are not terms
        """
        #expect(BenchGlossaryTerms.terms(fromMarkdown: markdown) == ["CORSIA", "My Supply", "proponent", "Siobhán Murphy"])
    }
}

@Suite struct PointRecallTests {
    let points = [
        RamblePoint(number: 1, label: "Goal", requirements: [
            KeywordGroup(alternatives: ["CORSIA"]), KeywordGroup(alternatives: ["filter", "column"]),
        ], retracted: ["Friday"]),
        RamblePoint(number: 2, label: "Ticket", requirements: [KeywordGroup(alternatives: ["AB-1234"])]),
        RamblePoint(number: 3, label: "Percentage", requirements: [KeywordGroup(alternatives: ["12", "twelve"])]),
    ]

    @Test func reportsCoveredPoints() {
        let text = "Add a CORSIA column to the table. See ab 1234. The default is twelve percent."
        let result = PointRecall.evaluate(points: points, text: text)
        #expect(result.coveredCount == 3)
        #expect(result.summary == "3/3")
        #expect(result.recall == 1)
        #expect(result.missing.isEmpty)
    }

    @Test func allOfGroupsAreRequired() {
        // Point 1 needs CORSIA AND (filter | column): only one group is present.
        let result = PointRecall.evaluate(points: points, text: "Add a filter. AB-1234. 12%")
        #expect(result.coveredCount == 2)
        let first = result.points[0]
        #expect(first.covered == false)
        #expect(first.matchedGroups == 1)
        #expect(first.totalGroups == 2)
        #expect(first.matched == [nil, "filter"])
        #expect(first.missingGroups == ["CORSIA"])
        #expect(result.missing.map(\.point.number) == [1])
    }

    @Test func wholeWordPhraseMatching() {
        let result = PointRecall.evaluate(points: points, text: "CORSIA filter AB-12345 and 120 percent")
        #expect(result.points[1].covered == false)
        #expect(result.points[2].covered == false)
        #expect(PointRecall.contains(["supply", "table"], phrase: "Supply Table"))
        #expect(!PointRecall.contains(["supply", "tables"], phrase: "supply table"))
        #expect(!PointRecall.contains(["a"], phrase: ""))
        #expect(!PointRecall.contains([], phrase: "a"))
    }

    @Test func retractedPhrasesAreReportedButDoNotChangeCoverage() {
        let result = PointRecall.evaluate(points: points, text: "CORSIA filter by Friday, no, Thursday. AB-1234. Twelve.")
        #expect(result.points[0].covered)
        #expect(result.points[0].retractedFound == ["Friday"])
        #expect(result.withRetracted.map(\.point.number) == [1])
    }

    @Test func noPoints() {
        let result = PointRecall.evaluate(points: [], text: "anything")
        #expect(result.recall == nil)
        #expect(result.summary == "0/0")
    }
}

@Suite struct BenchReportTests {
    let rows = [
        BenchRow(sample: "s01", engine: "parakeet", mode: "raw", wer: 0.1234, termHits: 2, termTotal: 3,
                 timings: BenchTimings(modelLoad: 1.5, transcribe: 0.25, tailLatency: 0.4)),
        BenchRow(sample: "s02", engine: "parakeet", mode: "raw", wer: 0.0, termHits: 1, termTotal: 1,
                 timings: BenchTimings(modelLoad: 1.5, transcribe: 0.35)),
        BenchRow(sample: "ramble", engine: "parakeet", mode: "structure", model: "sonnet", wer: 0.2,
                 pointsCovered: 7, pointsTotal: 8,
                 timings: BenchTimings(transcribe: 3, claudeFirstByte: 2.5, claudeTotal: 20)),
    ]

    @Test func markdownTable() {
        let markdown = BenchReport(title: "Bench", note: "Run on an M1 Pro.", rows: rows).markdown()
        #expect(markdown.hasPrefix("# Bench\n\nRun on an M1 Pro.\n\n## Results\n\n"))
        #expect(markdown.contains("| Sample | Engine | Mode | Model | WER | Terms | Points | Load | Transcribe | Tail | Claude 1st byte | Claude total |"))
        #expect(markdown.contains("| s01 | parakeet | raw | – | 12.3% | 2/3 (67%) | – | 1.50 s | 0.25 s | 0.40 s | – | – |"))
        #expect(markdown.contains("| ramble | parakeet | structure | sonnet | 20.0% | – | 7/8 | – | 3.00 s | – | 2.50 s | 20.00 s |"))
    }

    @Test func summaryPoolsTermsAndAveragesTimes() {
        let markdown = BenchReport(rows: rows).markdown()
        #expect(markdown.contains("## Summary"))
        // parakeet/raw: two samples, WER mean (0.1234 + 0) / 2 = 6.2%, terms 3/4 (75%), transcribe mean 0.30 s.
        #expect(markdown.contains("| parakeet | raw | – | 2 | 6.2% | 3/4 (75%) | – | 1.50 s | 0.30 s | 0.40 s | – | – |"))
        #expect(markdown.contains("| parakeet | structure | sonnet | 1 | 20.0% | – | 7/8 |"))
    }

    @Test func emptyReportHasNoSummary() {
        let markdown = BenchReport(rows: []).markdown()
        #expect(!markdown.contains("## Summary"))
    }

    @Test func pipesInCellsAreEscaped() {
        let row = BenchRow(sample: "a|b", engine: "e", mode: "raw")
        #expect(BenchReport(rows: [row]).markdown().contains("| a\\|b |"))
    }

    @Test func csv() {
        let csv = BenchReport(rows: rows).csv()
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0] == "sample,engine,mode,model,wer,term_hits,term_total,term_hit_rate,points_covered,points_total,point_recall,model_load_s,transcribe_s,tail_latency_s,claude_first_byte_s,claude_total_s")
        #expect(lines[1] == "s01,parakeet,raw,,0.1234,2,3,0.6667,,,,1.500,0.250,0.400,,")
        #expect(lines[3] == "ramble,parakeet,structure,sonnet,0.2000,,,,7,8,0.8750,,3.000,,2.500,20.000")
        #expect(csv.hasSuffix("\n"))
    }

    @Test func csvQuoting() {
        #expect(BenchReport.csvField("plain") == "plain")
        #expect(BenchReport.csvField("a,b") == "\"a,b\"")
        #expect(BenchReport.csvField("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(BenchReport.csvField("two\nlines") == "\"two\nlines\"")
    }

    @Test func rowFromScore() {
        let score = BenchScorer.score(reference: "Check CORSIA on AB-1234", hypothesis: "check core sea on AB-1234",
                                      glossaryTerms: ["CORSIA"])
        let row = BenchRow(sample: "s01", engine: "whisper", mode: "raw", score: score)
        // Terms: CORSIA missed, AB-1234 found (added from the reference). WER: "AB-1234" is two words, so the reference has 5 words and the hypothesis adds "sea" and
        // swaps "corsia" for "core": one substitution and one insertion, 2/5.
        #expect(row.termHits == 1)
        #expect(row.termTotal == 2)
        #expect(row.termHitRate == 0.5)
        #expect(abs(row.wer! - 0.4) < 1e-12)
        #expect(row.pointsTotal == nil)
    }
}

@Suite struct BenchCorpusFileTests {
    @Test func sentencesParseFromTheRealFile() throws {
        let text = try String(contentsOf: benchDirectory.appendingPathComponent("sentences.md"), encoding: .utf8)
        let sentences = try SentenceCorpusParser.parse(text)
        #expect(sentences.map(\.id) == (1...10).map { String(format: "s%02d", $0) })
        #expect(sentences[0].text == "Can you check whether the CORSIA eligibility flag is set on every project in My Supply before Friday?")
        #expect(sentences[3].hasPlaceholder)
        #expect(sentences[8].text.hasPrefix("⟨teammate⟩ and ⟨teammate⟩"))
        #expect(!sentences[1].hasPlaceholder)
        #expect(sentences[9].text.contains("\"nationally determined contribution\""))
    }

    @Test func rambleOutlineParsesFromTheRealFile() throws {
        let text = try String(contentsOf: benchDirectory.appendingPathComponent("ramble-outline.md"), encoding: .utf8)
        let points = try RambleOutlineParser.parse(text)
        #expect(points.count == 8)
        #expect(points.map(\.number) == Array(1...8))
        #expect(points.allSatisfy { !$0.requirements.isEmpty && $0.prompt != nil })
        // Two ticket IDs and a file path are in the outline.
        let all = points.flatMap(\.requirements).flatMap(\.alternatives)
        #expect(all.contains("AB-1234"))
        #expect(all.contains("AB-2210"))
        #expect(all.contains { $0.contains("/") && $0.hasSuffix(".tsx") })
        // Self-corrections are recorded.
        #expect(points[0].retracted.contains("by Friday"))
        #expect(points[2].retracted.contains("ten percent"))
        #expect(points[3].retracted == ["AB-1243"])
    }

    @Test func aGoodStructureTextCoversEveryPointAndABadOneDoesNot() throws {
        let text = try String(contentsOf: benchDirectory.appendingPathComponent("ramble-outline.md"), encoding: .utf8)
        let points = try RambleOutlineParser.parse(text)
        let good = """
        Add a CORSIA eligibility column and filter to the My Supply table, ready by Thursday.
        Table: src/features/my-supply/SupplyTable.tsx, with the filter state next to it.
        The buffer pool contribution defaults to twelve percent, from config.
        Fix AB-1234: the retirements endpoint returns a 500 without a vintage. Write a failing test first.
        AB-2210: show the Article 6 letter as a link on the row.
        Use a reversible Supabase migration, run on staging first; leave the retirements columns alone.
        Add three tests, run pnpm test, keep the PR under 400 lines.
        Question: should a proponent without a signed ERPA be excluded or flagged?
        """
        let result = PointRecall.evaluate(points: points, text: good)
        #expect(result.summary == "8/8")
        #expect(result.withRetracted.isEmpty)

        let bad = PointRecall.evaluate(points: points, text: "Add a CORSIA column. Fix AB-1234.")
        #expect(bad.coveredCount < 8)
        #expect(bad.points[3].covered == false)
    }

    @Test func parserErrors() {
        #expect(throws: BenchParseError.self) { try SentenceCorpusParser.parse("nothing here") }
        #expect(throws: BenchParseError.duplicateID("s01")) { try SentenceCorpusParser.parse("- s01: a\n- s01: b") }
        #expect(throws: BenchParseError.self) { try SentenceCorpusParser.parse("- s01:   ") }
        #expect(throws: BenchParseError.self) { try RambleOutlineParser.parse("### 1. A\n- say: hi") }
        #expect(throws: BenchParseError.self) { try RambleOutlineParser.parse("### 2. Skipped one\n- keywords: a") }
        #expect(throws: BenchParseError.self) { try RambleOutlineParser.parse("### 1. A\n- keywords: a ; ") }
        #expect(throws: BenchParseError.self) { try RambleOutlineParser.parse("# Nothing") }
        #expect(throws: BenchParseError.self) { try RambleOutlineParser.parse("### 1. A\n- keywords: percent | %") }
        #expect(throws: BenchParseError.self) { try RambleOutlineParser.parse("### 1. A\n- keywords: a\n- retracted: 10 percent | %") }
    }

    @Test func parserSmallCases() throws {
        let sentences = try SentenceCorpusParser.parse("# Title\n\nprose: x\n- not-an-id: y\n- s02: Second.\n  - s03: Indented one.\n")
        #expect(sentences.map(\.id) == ["s02", "s03"])
        let points = try RambleOutlineParser.parse("""
        ## 1. One
        - say: talk
        - keywords: a | b ; c
        - retracted: x | y
        #### 2. Two
        - keywords: d
        """)
        #expect(points[0].requirements == [KeywordGroup(alternatives: ["a", "b"]), KeywordGroup(alternatives: ["c"])])
        #expect(points[0].retracted == ["x", "y"])
        #expect(points[0].prompt == "talk")
        #expect(points[1].prompt == nil)
    }

    @Test func glossarySampleCoversTheCorpusJargon() throws {
        let markdown = try String(contentsOf: benchDirectory.appendingPathComponent("glossary.sample.md"), encoding: .utf8)
        let terms = BenchGlossaryTerms.terms(fromMarkdown: markdown)
        for expected in ["CORSIA", "My Supply", "NDC", "proponent", "procurement", "PDD", "Article 6", "ARR", "ERPA",
                         "UNFCCC", "Supabase", "Verra", "Gold Standard", "buffer pool", "retirements", "In Progress",
                         "vintage", "registry", "corresponding adjustment", "Declan Hollings"] {
            #expect(terms.contains(expected), "missing \(expected)")
        }
        #expect(!terms.contains("AB-{n}"))
        // Every glossary term that appears in a sentence is spelled as in the glossary (so a perfect transcript hits all).
        let sentences = try SentenceCorpusParser.parse(
            String(contentsOf: benchDirectory.appendingPathComponent("sentences.md"), encoding: .utf8))
        let joined = sentences.map(\.text).joined(separator: "\n")
        let result = TermHitRate.evaluate(terms: terms, reference: joined, hypothesis: joined)
        #expect(result.rate == 1)
        #expect(result.terms.count >= 12)
    }

    @Test func corpusLoadsFromTheRealFolder() throws {
        let corpus = try BenchCorpus.load(directory: benchDirectory)
        #expect(corpus.sentences.count == 10)
        #expect(corpus.ramblePoints.count == 8)
        #expect(corpus.samples.map(\.id) == (1...10).map { String(format: "s%02d", $0) } + ["ramble"])
        #expect(corpus.samples.last?.isRamble == true)
        #expect(corpus.glossaryURL?.lastPathComponent == "glossary.sample.md" || corpus.glossaryURL?.lastPathComponent == "glossary.md")
        #expect(corpus.glossaryTerms.contains("CORSIA"))
        #expect(corpus.points(for: corpus.samples[0]) == nil)
        #expect(corpus.points(for: corpus.samples[10])?.count == 8)
    }

    @Test func corpusFindsFilesAndReferences() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("references"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("superwhisper"), withIntermediateDirectories: true)
        try "- s01: One.\n".write(to: root.appendingPathComponent("sentences.md"), atomically: true, encoding: .utf8)
        try "### 1. P\n- keywords: x\n".write(to: root.appendingPathComponent("ramble-outline.md"), atomically: true, encoding: .utf8)
        try "  Reference text.\n".write(to: root.appendingPathComponent("references/s01.txt"), atomically: true, encoding: .utf8)
        try "Heard text".write(to: root.appendingPathComponent("superwhisper/s01.txt"), atomically: true, encoding: .utf8)
        let corpus = try BenchCorpus.load(directory: root)
        let s01 = corpus.samples[0]
        #expect(try corpus.reference(for: s01) == "Reference text.")
        #expect(try corpus.superwhisperText(for: s01) == "Heard text")
        #expect(s01.audioURL == nil)
        #expect(corpus.glossaryURL == nil)
        #expect(try corpus.reference(for: corpus.samples[1]) == nil)
    }
}
