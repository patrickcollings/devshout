import Foundation
import Testing
@testable import DevshoutCore

private let glossary = GlossaryParser.parse("""
    ## Terms
    - **CORSIA** — an aviation offsetting scheme
      - heard: core sea
    - **My Supply** — a product area
    - **proponent** — the developer of a project
    - **NDC**

    ## People
    - **Siobhán Murphy**

    ## Patterns
    - **AB-{n}** — ticket IDs
    """)

private func sentence(_ id: String, _ text: String, terms: [String] = []) -> CalibrationSentence {
    CalibrationSentence(id: id, text: text, kind: terms.isEmpty ? .general : .glossary, terms: terms)
}

/// An engine score with `errors` wrong out of `words`, `hits` of `terms` and a speed.
private func engineScore(_ engine: EngineID, words: Int = 150, errors: Int, terms: Int = 10, hits: Int = 10,
                         secondsPerMinute: Double = 3) -> CalibrationEngineScore {
    CalibrationEngineScore(engine: engine, sentences: [
        CalibrationSentenceScore(sentenceID: "c01", transcript: "", audioSeconds: 60, processingSeconds: secondsPerMinute,
                                 referenceWords: words, wordErrors: errors, termCount: terms, termHits: hits),
    ])
}

@Suite struct CalibrationScoringTests {
    @Test func aSentenceIsScoredWithTheBenchMetrics() {
        let s = sentence("c06", "Check the CORSIA flag on AB-1482 in My Supply for 45 minutes.", terms: ["CORSIA", "My Supply"])
        let score = CalibrationScorer.score(sentence: s, transcript: "Check the core sea flag on AB-1482 in my supply for forty-five minutes",
                                            audioSeconds: 6, processingSeconds: 0.3,
                                            glossaryTerms: CalibrationScorer.glossaryTerms(glossary))
        // "CORSIA" → "core sea" is one substitution and one insertion; the number is the same number.
        #expect(score.referenceWords == 13)
        #expect(score.wordErrors == 2)
        // CORSIA, My Supply and the ticket are in the sentence; only the ticket came out exactly right.
        #expect(score.termCount == 3)
        #expect(score.termHits == 1)
        #expect(CalibrationScorer.glossaryTerms(glossary) == ["CORSIA", "My Supply", "proponent", "NDC", "Siobhán Murphy"])
    }

    @Test func anEngineScoreAddsUpItsSentences() {
        let score = CalibrationEngineScore(engine: .parakeetV3, sentences: [
            CalibrationSentenceScore(sentenceID: "c01", transcript: "a", audioSeconds: 6, processingSeconds: 0.2,
                                     referenceWords: 10, wordErrors: 1, termCount: 0, termHits: 0),
            CalibrationSentenceScore(sentenceID: "c02", transcript: "b", audioSeconds: 4, processingSeconds: 0.3,
                                     referenceWords: 30, wordErrors: 3, termCount: 4, termHits: 3),
        ])
        #expect(score.wordAccuracy == 0.9)
        #expect(score.termHitRate == 0.75)
        #expect(abs((score.secondsPerMinute ?? 0) - 3.0) < 0.0001)
        #expect(CalibrationReport.accuracy(score) == "90%")
        #expect(CalibrationReport.terms(score) == "3 of 4 (75%)")
        #expect(CalibrationReport.speed(score) == "3.0 s per minute of audio")

        let nothing = CalibrationEngineScore(engine: .parakeetV3, sentences: [])
        #expect(nothing.wordAccuracy == 0)
        #expect(nothing.termHitRate == nil)
        #expect(nothing.secondsPerMinute == nil)
        // More errors than words (lots of insertions) never goes below zero.
        #expect(engineScore(.parakeetV3, words: 5, errors: 9).wordAccuracy == 0)
    }

    @Test func aClearWinnerIsRecommended() {
        let scores = [engineScore(.parakeetV3, errors: 16, secondsPerMinute: 2),
                      engineScore(.whisperLargeV3Turbo, errors: 6, secondsPerMinute: 8)]
        let recommendation = CalibrationRecommendation.decide(scores)
        #expect(recommendation == CalibrationRecommendation(verdict: .better, engine: .whisperLargeV3Turbo, other: .parakeetV3))
        #expect(recommendation.summary(scores: scores)
                == "Whisper understood you better: 96% of your words right against 89%. Parakeet is about four times faster.")
        // The order the engines were measured in doesn't matter.
        #expect(CalibrationRecommendation.decide(scores.reversed()) == recommendation)
    }

    @Test func aWinnerThatIsAlsoFasterSaysSo() {
        let scores = [engineScore(.parakeetV3, errors: 4, secondsPerMinute: 2),
                      engineScore(.whisperLargeV3Turbo, errors: 15, secondsPerMinute: 4)]
        let recommendation = CalibrationRecommendation.decide(scores)
        #expect(recommendation.engine == .parakeetV3)
        #expect(recommendation.summary(scores: scores)
                == "Parakeet understood you better: 97% of your words right against 90%. It is also about twice as fast.")
    }

    @Test func aSmallGapIsAboutTheSameAndTheFasterEngineIsTheChoice() {
        // Two words out of 150 apart: 1.3 points.
        let scores = [engineScore(.parakeetV3, errors: 9, secondsPerMinute: 2),
                      engineScore(.whisperLargeV3Turbo, errors: 7, secondsPerMinute: 8)]
        let recommendation = CalibrationRecommendation.decide(scores)
        #expect(recommendation == CalibrationRecommendation(verdict: .aboutTheSame, engine: .parakeetV3, other: .whisperLargeV3Turbo))
        #expect(recommendation.summary(scores: scores)
                == "Whisper and Parakeet understood you about the same: 95% and 94% of your words right. "
                + "A few sentences are a small sample, so a gap this small doesn't mean much. "
                + "Parakeet is about four times faster, so it is the better choice.")
    }

    @Test func aboutTheSameWithSimilarSpeedRecommendsNothing() {
        let scores = [engineScore(.parakeetV3, errors: 9, secondsPerMinute: 3),
                      engineScore(.whisperLargeV3Turbo, errors: 8, secondsPerMinute: 4)]
        let recommendation = CalibrationRecommendation.decide(scores)
        #expect(recommendation == CalibrationRecommendation(verdict: .aboutTheSame))
        #expect(recommendation.summary(scores: scores).hasSuffix("a gap this small doesn't mean much."))
    }

    @Test func aBigPercentageGapOnAShortScriptIsStillAboutTheSame() {
        // 20 words: two words apart is ten points, but it is only two words.
        let scores = [engineScore(.parakeetV3, words: 20, errors: 3), engineScore(.whisperLargeV3Turbo, words: 20, errors: 1)]
        #expect(CalibrationRecommendation.decide(scores).verdict == .aboutTheSame)
        // Exactly on the thresholds counts as better: 3 words and 3 points of 100.
        let edge = [engineScore(.parakeetV3, words: 100, errors: 5), engineScore(.whisperLargeV3Turbo, words: 100, errors: 2)]
        #expect(CalibrationRecommendation.decide(edge).verdict == .better)
    }

    @Test func glossaryTermsDecideWhenOrdinaryWordsDoNot() {
        let scores = [engineScore(.parakeetV3, errors: 8, hits: 6, secondsPerMinute: 2),
                      engineScore(.whisperLargeV3Turbo, errors: 9, hits: 9, secondsPerMinute: 8)]
        let recommendation = CalibrationRecommendation.decide(scores)
        #expect(recommendation == CalibrationRecommendation(verdict: .betterOnTerms, engine: .whisperLargeV3Turbo, other: .parakeetV3))
        #expect(recommendation.summary(scores: scores)
                == "Both got about the same share of ordinary words right (94% and 95%), but Whisper got more of your "
                + "glossary terms right: 9 of 10 against 6 of 10.")
        // One term apart is not enough.
        let close = [engineScore(.parakeetV3, errors: 8, hits: 8), engineScore(.whisperLargeV3Turbo, errors: 9, hits: 9)]
        #expect(CalibrationRecommendation.decide(close).verdict == .aboutTheSame)
    }

    @Test func oneEngineOrNone() {
        let one = [engineScore(.parakeetV3, errors: 10)]
        let recommendation = CalibrationRecommendation.decide(one)
        #expect(recommendation == CalibrationRecommendation(verdict: .onlyOne, engine: .parakeetV3))
        #expect(recommendation.summary(scores: one, notCompared: [.whisperLargeV3Turbo])
                == "Parakeet got 93% of your words right. Download Whisper in Settings → Transcription and calibrate again to compare the two.")
        #expect(recommendation.summary(scores: one) == "Parakeet got 93% of your words right.")
        #expect(CalibrationRecommendation.decide([]).verdict == .none)
        #expect(CalibrationRecommendation.decide([CalibrationEngineScore(engine: .parakeetV3, sentences: [])]).verdict == .none)
    }
}

@Suite struct CalibrationLearningTests {
    /// Words the fake spelling checker knows.
    static let dictionary: Set<String> = ["core", "sea", "component", "my", "supplies", "and", "see", "walk", "work",
                                          "the", "on", "shiv"]
    static func isOrdinary(_ word: String) -> Bool { dictionary.contains(word) }

    func observe(_ engine: EngineID, _ reference: String, _ transcript: String) -> CalibrationLearning.Observation {
        .init(engine: engine, sentence: sentence("c01", reference), transcript: transcript)
    }

    func corrections(_ observations: [CalibrationLearning.Observation]) -> [LearnedCorrection] {
        CalibrationLearning.corrections(observations: observations, glossary: glossary, isOrdinaryWord: Self.isOrdinary)
    }

    @Test func aMisheardTermThatIsNotAWordIsSuggested() {
        let found = corrections([observe(.parakeetV3, "Check the CORSIA flag today.", "Check the causia flag today.")])
        #expect(found == [LearnedCorrection(term: "CORSIA", heard: "causia", engines: [.parakeetV3], count: 1, isOrdinaryPhrase: false)])
        #expect(found[0].isSuggested)
    }

    @Test func anOrdinaryWordIsOfferedButNotTicked() {
        let found = corrections([observe(.whisperLargeV3Turbo, "Ask the proponent for the letter.", "Ask the component for the letter.")])
        #expect(found == [LearnedCorrection(term: "proponent", heard: "component", engines: [.whisperLargeV3Turbo], count: 1,
                                            isOrdinaryPhrase: true)])
        #expect(!found[0].isSuggested)
    }

    @Test func aTermSplitIntoSeveralWordsIsReadWhole() {
        // The alignment pairs NDC with one of the words and inserts the others beside it.
        let found = corrections([observe(.parakeetV3, "Map each NDC target to its country.", "Map each and see target to its country.")])
        #expect(found.map(\.heard) == ["and see"])
        #expect(found[0].term == "NDC")
        #expect(found[0].isOrdinaryPhrase)
        // A phrase with one word that isn't a word is safe to replace.
        let other = corrections([observe(.parakeetV3, "Map each NDC target.", "Map each endy see target.")])
        #expect(other.map(\.heard) == ["endy see"])
        #expect(other[0].isSuggested)
    }

    @Test func multiWordTermsAndNames() {
        let found = corrections([
            observe(.parakeetV3, "Open My Supply and sort it.", "Open my supplies and sort it."),
            observe(.parakeetV3, "Ask Siobhán Murphy about it.", "Ask shiv on Murphy about it."),
        ])
        #expect(found.map(\.term) == ["My Supply", "Siobhán Murphy"])
        #expect(found.map(\.heard) == ["my supplies", "shiv on murphy"])
        #expect(found.map(\.isOrdinaryPhrase) == [true, false])
    }

    @Test func whatIsAlreadyKnownOrNotAMishearingIsLeftOut() {
        // Right; right but for capitals; dropped altogether; already a heard form; another glossary term.
        #expect(corrections([observe(.parakeetV3, "Check the CORSIA flag.", "check the CORSIA flag")]).isEmpty)
        #expect(corrections([observe(.parakeetV3, "Check the CORSIA flag.", "Check the Corsia flag.")]).isEmpty)
        #expect(corrections([observe(.parakeetV3, "Check the CORSIA flag.", "Check the flag.")]).isEmpty)
        #expect(corrections([observe(.parakeetV3, "Check the CORSIA flag.", "Check the core sea flag.")]).isEmpty)
        #expect(corrections([observe(.parakeetV3, "Check the CORSIA flag.", "Check the NDC flag.")]).isEmpty)
        // Ticket IDs come from a pattern, not an entry: nothing to add a heard form to.
        #expect(corrections([observe(.parakeetV3, "Move AB-1482 up.", "Move a b 1482 up.")]).isEmpty)
        // A long run of extra words is noise, not a mishearing.
        #expect(corrections([observe(.parakeetV3, "Check the NDC flag.", "Check the one two three four five six flag.")]).isEmpty)
    }

    @Test func theSameMishearingIsCountedAcrossEnginesAndSentences() {
        let found = corrections([
            observe(.whisperLargeV3Turbo, "Check the CORSIA flag.", "Check the causia flag."),
            observe(.parakeetV3, "Check the CORSIA flag.", "Check the causia flag."),
            observe(.parakeetV3, "Is CORSIA in force?", "Is causia in force?"),
            observe(.parakeetV3, "Ask the proponent.", "Ask the proponant."),
        ])
        #expect(found.map(\.heard) == ["causia", "proponant"])
        #expect(found[0].count == 3)
        #expect(found[0].engines == [.parakeetV3, .whisperLargeV3Turbo])
        #expect(found[1].engines == [.parakeetV3])
    }

    @Test func learnedCorrectionsWorkInTheTextFixer() {
        let found = corrections([observe(.parakeetV3, "Check the CORSIA flag in My Supply.", "Check the causia flag in mice apply.")])
        var markdown = GlossaryWriter.markdown(glossary)
        for correction in found {
            markdown = GlossaryEditor.addingCorrection(heard: correction.heard, term: correction.term, to: markdown)
        }
        let fixed = TextFixer.fix("the causia rules and mice apply", glossary: GlossaryParser.parse(markdown))
        #expect(fixed.text == "the CORSIA rules and My Supply")
    }

    @Test func ordinaryWordSwapsBecomeStyleNotesWhenBothEnginesAgree() {
        let observations = [
            observe(.parakeetV3, "I will work on the report.", "I will walk on the report."),
            observe(.whisperLargeV3Turbo, "I will work on the report.", "I will walk on the report."),
            // Seen once by one engine only: not consistent enough.
            observe(.parakeetV3, "Send the draft today.", "Send the craft today."),
        ]
        let notes = CalibrationLearning.styleNotes(observations: observations, glossary: glossary)
        #expect(notes == [LearnedStyleNote(said: "work", written: "walk", engines: [.parakeetV3, .whisperLargeV3Turbo], count: 2)])
        #expect(notes[0].text == "This speaker's dictation often writes \"walk\" where they said \"work\"; use the context to decide which is meant.")
    }

    @Test func withOneEngineEverySwapIsOfferedUpToTheLimit() {
        let observations = [
            observe(.parakeetV3, "I will work on the report.", "I will walk on the report."),
            observe(.parakeetV3, "Send the draft today.", "Send the craft today."),
            observe(.parakeetV3, "The work is done.", "The walk is done."),
            observe(.parakeetV3, "Ship the build tonight.", "Sheep the build tonight."),
            observe(.parakeetV3, "Close the ticket please.", "Close the thicket please."),
        ]
        let notes = CalibrationLearning.styleNotes(observations: observations, glossary: glossary)
        #expect(notes.count == CalibrationLearning.styleNoteLimit)
        #expect(notes[0].said == "work")
        #expect(notes[0].count == 2)
        #expect(notes.map(\.said) == ["work", "draft", "ship"])
    }

    @Test func noiseIsNotAStyleNote() {
        func notes(_ reference: String, _ transcript: String) -> [LearnedStyleNote] {
            CalibrationLearning.styleNotes(observations: [observe(.parakeetV3, reference, transcript)], glossary: glossary)
        }
        // Glossary terms are corrections, not notes.
        #expect(notes("Ask the proponent now.", "Ask the component now.").isEmpty)
        // Numbers, very short words and spelling variants.
        #expect(notes("Wait 45 minutes here.", "Wait 55 minutes here.").isEmpty)
        #expect(notes("It is on the list.", "It is in the list.").isEmpty)
        #expect(notes("We organise the files.", "We organize the files.").isEmpty)
        // A swap next to a dropped or added word is probably a misalignment.
        #expect(notes("Send the long draft today.", "Send the craft today.").isEmpty)
    }

    @Test func styleNotesGoIntoTheStyleSection() {
        let note = "This speaker's dictation often writes \"walk\" where they said \"work\"; use the context to decide which is meant."
        let text = "## Terms\n- **A**\n\n## Style\nUse British English.\n\n## People\n- **P**\n"
        let out = GlossaryEditor.addingStyleNotes([note, note], to: text)
        #expect(out == "## Terms\n- **A**\n\n## Style\nUse British English.\n- \(note)\n\n## People\n- **P**\n")
        #expect(GlossaryParser.parse(out).styleText.contains(note))
        // Adding it again changes nothing.
        #expect(GlossaryEditor.addingStyleNotes([note], to: out) == out)
        // No Style section yet.
        #expect(GlossaryEditor.addingStyleNotes(["Note one."], to: "## Terms\n- **A**") == "## Terms\n- **A**\n\n## Style\n- Note one.\n")
        #expect(GlossaryEditor.addingStyleNotes([], to: text) == text)
        #expect(GlossaryEditor.addingStyleNotes(["  "], to: text) == text)
    }

    @Test func styleNotesWorkOnTheStarterTemplate() {
        let out = GlossaryEditor.addingStyleNotes(["Note one."], to: GlossaryFile.starterTemplate)
        #expect(out.hasSuffix("-->\n- Note one.\n"))
        let parsed = GlossaryParser.parse(out)
        #expect(parsed.styleText == "- Note one.")
        #expect(parsed.allEntries.isEmpty)
    }
}

@Suite struct CalibrationRecordTests {
    func record(date: Date = Date(timeIntervalSince1970: 1_794_000_000)) -> CalibrationRecord {
        let sentences = [sentence("c01", "Check the login page."), sentence("c02", "Check the CORSIA flag.", terms: ["CORSIA"])]
        let scores = [
            CalibrationEngineScore(engine: .parakeetV3, sentences: [
                CalibrationSentenceScore(sentenceID: "c01", transcript: "Check the login page.", audioSeconds: 3,
                                         processingSeconds: 0.1, referenceWords: 4, wordErrors: 0, termCount: 0, termHits: 0),
                CalibrationSentenceScore(sentenceID: "c02", transcript: "Check the causia flag.", audioSeconds: 3,
                                         processingSeconds: 0.1, referenceWords: 4, wordErrors: 1, termCount: 1, termHits: 0),
            ]),
            CalibrationEngineScore(engine: .whisperLargeV3Turbo, sentences: [
                CalibrationSentenceScore(sentenceID: "c01", transcript: "Check the login page.", audioSeconds: 3,
                                         processingSeconds: 0.4, referenceWords: 4, wordErrors: 0, termCount: 0, termHits: 0),
                CalibrationSentenceScore(sentenceID: "c02", transcript: "Check the CORSIA flag.", audioSeconds: 3,
                                         processingSeconds: 0.4, referenceWords: 4, wordErrors: 0, termCount: 1, termHits: 1),
            ]),
        ]
        return CalibrationRecord(date: date, sentences: sentences, engines: scores,
                                 failures: [], selectedEngine: .parakeetV3,
                                 applied: .init(corrections: [.init(term: "CORSIA", heard: "causia")],
                                                styleNotes: ["A note."], switchedTo: .whisperLargeV3Turbo))
    }

    @Test func roundTripsThroughJSON() throws {
        let original = record()
        let data = try CalibrationRecord.encoder().encode(original)
        let decoded = try CalibrationRecord.decoder().decode(CalibrationRecord.self, from: data)
        #expect(decoded == original)
        #expect(decoded.version == 1)
        #expect(decoded.accuracySummary == "Whisper 100%, Parakeet 88%")
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"date\" : \"2026-11-06T"))
        #expect(json.contains("\"whisper-large-v3-turbo\""))
    }

    @Test func decodingToleratesMissingAndUnknownFields() throws {
        let json = """
            {"date": "2026-11-10T14:30:12Z", "version": 2, "paceWordsPerMinute": 171,
             "engines": [{"engine": "parakeet-tdt-0.6b-v3", "silenceProfile": {"median": 0.4},
                          "sentences": [{"sentenceID": "c01", "transcript": "hello there", "audioSeconds": 2,
                                         "processingSeconds": 0.1, "referenceWords": 2, "wordErrors": 0,
                                         "termCount": 0, "termHits": 0}]}],
             "sentences": [{"id": "c01", "text": "Hello there."}]}
            """
        let decoded = try CalibrationRecord.decoder().decode(CalibrationRecord.self, from: Data(json.utf8))
        #expect(decoded.version == 2)
        #expect(decoded.sentences == [CalibrationSentence(id: "c01", text: "Hello there.", kind: .general)])
        #expect(decoded.engines.first?.wordAccuracy == 1)
        #expect(decoded.recommendation == CalibrationRecommendation(verdict: .onlyOne, engine: .parakeetV3))
        #expect(decoded.applied == CalibrationRecord.Applied())
        #expect(decoded.failures.isEmpty)
    }

    @Test func theStoreKeepsResultsAndPrunesOldAudio() throws {
        let root = try ClaudeTestSupport.temporaryDirectory("calibration")
        let store = CalibrationStore(root: root.appendingPathComponent("Calibration"))
        #expect(store.latest() == nil)

        let utc = TimeZone(identifier: "UTC")!
        let firstDate = Date(timeIntervalSince1970: 1_794_000_000)
        let first = store.sessionDirectory(startingAt: firstDate, timeZone: utc)
        #expect(first.lastPathComponent == "2026-11-06-212000")
        let abandoned = store.sessionDirectory(startingAt: firstDate.addingTimeInterval(3600), timeZone: utc)
        let second = store.sessionDirectory(startingAt: firstDate.addingTimeInterval(7200), timeZone: utc)
        for session in [first, abandoned, second] {
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            try Data("RIFF".utf8).write(to: CalibrationStore.audioURL(for: "c01", in: session))
        }
        #expect(CalibrationStore.audioURL(for: "c01", in: first).lastPathComponent == "c01.wav")

        try store.save(record(date: firstDate), in: first)
        #expect(store.latest()?.date == firstDate)
        let later = record(date: firstDate.addingTimeInterval(7200))
        try store.save(later, in: second)
        #expect(store.latest() == later)

        store.prune(keeping: second)
        let fileManager = FileManager.default
        // The older session keeps its result but not its audio; the one with no result goes; the current one stays whole.
        #expect(fileManager.fileExists(atPath: first.appendingPathComponent("result.json").path))
        #expect(!fileManager.fileExists(atPath: CalibrationStore.audioURL(for: "c01", in: first).path))
        #expect(!fileManager.fileExists(atPath: abandoned.path))
        #expect(fileManager.fileExists(atPath: CalibrationStore.audioURL(for: "c01", in: second).path))
        #expect(store.latest() == later)

        // A result that can't be read is skipped, not fatal.
        try Data("not json".utf8).write(to: second.appendingPathComponent("result.json"))
        #expect(store.latest()?.date == firstDate)
    }
}

@Suite struct CalibrationAnalyserTests {
    static let script = [
        sentence("c01", "Could you check the login page?"),
        sentence("c02", "Check the CORSIA flag in My Supply.", terms: ["CORSIA", "My Supply"]),
    ]
    static let recordings = script.map { CalibrationRecording(sentence: $0, audioURL: URL(fileURLWithPath: "/tmp/\($0.id).wav")) }

    /// What each engine "hears" for each sentence.
    static let heard: [EngineID: [String: String]] = [
        .parakeetV3: ["c01": "could you check the login page", "c02": "Check the causia flag in my supplies."],
        .whisperLargeV3Turbo: ["c01": "Could you check the login page?", "c02": "Check the CORSIA flag in My Supply."],
    ]

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        func add(_ event: String) { lock.withLock { _events.append(event) } }
        var events: [String] { lock.withLock { _events } }
    }

    func analyser(log: Log, failing: EngineID? = nil, failAt: String? = nil) -> CalibrationAnalyser {
        CalibrationAnalyser(
            prepare: { engine in
                log.add("prepare \(engine.shortName)")
                if engine == failing, failAt == nil { throw SpikeError.missingVAD }
            },
            transcribe: { recording, engine in
                log.add("\(engine.shortName) \(recording.sentence.id)")
                if engine == failing, recording.sentence.id == failAt { throw SpikeError.missingVAD }
                return CalibrationTranscript(text: Self.heard[engine]![recording.sentence.id]!, audioSeconds: 3,
                                             processingSeconds: engine == .parakeetV3 ? 0.1 : 0.4)
            },
            release: { engine in log.add("release \(engine.shortName)") },
            describe: { _ in "it broke" })
    }

    @Test func runsTheEnginesOneAfterAnotherAndScoresThem() async throws {
        let log = Log()
        let progress = Log()
        let analysis = try await analyser(log: log).run(
            recordings: Self.recordings, engines: [.parakeetV3, .whisperLargeV3Turbo], glossary: glossary, warmUp: false,
            progress: { step, index in
                progress.add(String(format: "%.2f", step.fraction(engineIndex: index, engineCount: 2)))
            })
        #expect(log.events == ["prepare Parakeet", "Parakeet c01", "Parakeet c02", "release Parakeet",
                               "prepare Whisper", "Whisper c01", "Whisper c02", "release Whisper"])
        #expect(progress.events == ["0.00", "0.00", "0.25", "0.50", "0.50", "0.50", "0.75", "1.00"])

        #expect(analysis.failures.isEmpty)
        #expect(analysis.scores.map(\.engine) == [.parakeetV3, .whisperLargeV3Turbo])
        let parakeet = analysis.scores[0], whisper = analysis.scores[1]
        #expect(parakeet.referenceWords == 13)
        #expect(parakeet.wordErrors == 2)
        #expect(parakeet.termHits == 0)
        #expect(parakeet.termCount == 2)
        #expect(whisper.wordAccuracy == 1)
        #expect(whisper.termHitRate == 1)
        #expect(abs((parakeet.secondsPerMinute ?? 0) - 2) < 0.0001)
        #expect(analysis.observations.count == 4)

        let corrections = CalibrationLearning.corrections(observations: analysis.observations, glossary: glossary,
                                                          isOrdinaryWord: { ["my", "supplies"].contains($0) })
        #expect(corrections.map(\.heard) == ["causia", "my supplies"])
        #expect(corrections.map(\.isSuggested) == [true, false])

        let report = CalibrationReport.text(sentences: Self.script, analysis: analysis, corrections: corrections,
                                            styleNotes: [], details: true)
        #expect(report.contains("Parakeet  85%"))
        #expect(report.contains("Whisper   100%"))
        #expect(report.contains("[x] heard \"causia\" → CORSIA   (Parakeet)"))
        #expect(report.contains("[ ] heard \"my supplies\" → My Supply   (Parakeet)   ordinary words"))
        #expect(report.contains("Parakeet  Check the causia flag in my supplies.   [2 of 7 words wrong]"))
    }

    @Test func eachEngineIsWarmedUpOnTheFirstRecordingBeforeItIsTimed() async throws {
        let log = Log()
        let analysis = try await analyser(log: log).run(recordings: Self.recordings, engines: [.parakeetV3], glossary: glossary)
        #expect(log.events == ["prepare Parakeet", "Parakeet c01", "Parakeet c01", "Parakeet c02", "release Parakeet"])
        // The warm-up isn't scored.
        #expect(analysis.scores[0].sentences.map(\.sentenceID) == ["c01", "c02"])
        #expect(CalibrationLearning.transcriptWords(analysis.observations).contains("causia"))
    }

    @Test func anEngineThatFailsIsReportedAndTheOtherStillRuns() async throws {
        let log = Log()
        let loadFailure = try await analyser(log: log, failing: .parakeetV3).run(
            recordings: Self.recordings, engines: [.parakeetV3, .whisperLargeV3Turbo], glossary: glossary, warmUp: false)
        #expect(loadFailure.failures == [CalibrationEngineFailure(engine: .parakeetV3, message: "it broke")])
        #expect(loadFailure.scores.map(\.engine) == [.whisperLargeV3Turbo])
        #expect(loadFailure.recommendation.verdict == .onlyOne)
        #expect(log.events.prefix(3) == ["prepare Parakeet", "release Parakeet", "prepare Whisper"])

        // Failing part-way through the script drops the engine rather than scoring it on less.
        let midFailure = try await analyser(log: Log(), failing: .whisperLargeV3Turbo, failAt: "c02").run(
            recordings: Self.recordings, engines: [.parakeetV3, .whisperLargeV3Turbo], glossary: glossary, warmUp: false)
        #expect(midFailure.scores.map(\.engine) == [.parakeetV3])
        #expect(midFailure.failures.map(\.engine) == [.whisperLargeV3Turbo])
        #expect(midFailure.observations.allSatisfy { $0.engine == .parakeetV3 })
    }

    @Test func cancellingStopsBetweenRecordingsAndReleasesTheEngine() async throws {
        let log = Log()
        let analyser = CalibrationAnalyser(
            prepare: { _ in },
            transcribe: { recording, engine in
                log.add("\(engine.shortName) \(recording.sentence.id)")
                withUnsafeCurrentTask { $0?.cancel() }
                return CalibrationTranscript(text: "", audioSeconds: 1, processingSeconds: 0.1)
            },
            release: { engine in log.add("release \(engine.shortName)") })
        let task = Task {
            try await analyser.run(recordings: Self.recordings, engines: [.parakeetV3, .whisperLargeV3Turbo],
                                   glossary: glossary, warmUp: false)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(log.events == ["Parakeet c01", "release Parakeet"])
    }

    @Test func aRecordingGoesThroughTheAppsPipeline() async throws {
        let engine = SpikeFakeEngine(id: .whisperLargeV3Turbo, fixedText: "check the core sea flag")
        let samples = [Float](repeating: 0.8, count: AudioFormat.sampleRate * 2)
        // Without a voice activity detector the recording goes to the engine whole; the glossary's fixes apply.
        let whole = try await CalibrationTranscriber.transcribe(samples: samples, engine: engine, vad: nil, glossary: glossary)
        #expect(whole.text == "check the CORSIA flag")
        #expect(whole.audioSeconds == 2)
        #expect(engine.contexts.count == 1)
        #expect(engine.contexts[0].vocabularyPrompt?.contains("CORSIA") == true)

        let withVAD = try await CalibrationTranscriber.transcribe(samples: samples, engine: engine, vad: SpikeFakeVAD(),
                                                                  glossary: glossary)
        #expect(withVAD.text == "check the CORSIA flag")
    }
}
