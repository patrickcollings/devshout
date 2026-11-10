import Foundation
import Testing
@testable import DevshoutCore

@Suite struct SpikeSupportTests {
    @Test func timingStats() throws {
        #expect(TimingStats([]) == nil)
        let odd = try #require(TimingStats([3, 1, 2]))
        #expect(odd.min == 1 && odd.max == 3 && odd.median == 2 && odd.count == 3)
        #expect(abs(odd.mean - 2) < 1e-9)
        let even = try #require(TimingStats([4, 1, 3, 2]))
        #expect(even.median == 2.5)
        #expect(even.summary == "min 1.00 s · median 2.50 s · max 4.00 s (4 runs)")
        #expect(TimingStats([0.5])?.summary == "min 500 ms · median 500 ms · max 500 ms (1 run)")
    }

    @Test func formatting() {
        #expect(SpikeFormat.seconds(0.0123) == "12 ms")
        #expect(SpikeFormat.seconds(1.234) == "1.23 s")
        #expect(SpikeFormat.seconds(75.24) == "75.2 s")
        #expect(SpikeFormat.clock(83.45) == "01:23.4")
        #expect(SpikeFormat.clock(0) == "00:00.0")
        #expect(SpikeFormat.clock(600) == "10:00.0")
        #expect(SpikeFormat.bytes(483_200_000) == "483 MB")
        #expect(SpikeFormat.bytes(1_500_000_000) == "1.50 GB")
        #expect(SpikeFormat.meter(0.5, width: 10) == "[#####-----]")
        #expect(SpikeFormat.meter(2, width: 4) == "[####]")
        #expect(SpikeFormat.meter(-1, width: 4) == "[----]")
        #expect(SpikeFormat.realTimeFactor(processing: 1, audio: 0) == nil)
        #expect(SpikeFormat.realTimeFactorDescription(0.0125) == "RTF 0.013 (80× faster than real time)")
        #expect(SpikeFormat.realTimeFactorDescription(2) == "RTF 2.000 (2.0× slower than real time)")
        #expect(SpikeFormat.realTimeFactorDescription(nil) == "RTF –")
    }

    @Test func maskedTokenNeverShowsTheMiddle() {
        let token = "sk-ant-oat01-" + String(repeating: "aB3_-", count: 18) + "xyzAA"
        let masked = SpikeFormat.maskedToken(token)
        #expect(masked == "sk-ant-oat01-…yzAA")
        #expect(!masked.contains("aB3_"))
        #expect(SpikeFormat.maskedToken("short") == "•••••")
    }

    @Test func paths() {
        let paths = SpikePaths(applicationSupport: URL(fileURLWithPath: "/Users/p/Library/Application Support"))
        #expect(paths.devshoutFolder.path == "/Users/p/Library/Application Support/devshout")
        #expect(paths.claudeConfigDirectory.path == "/Users/p/Library/Application Support/devshout/claude")
        #expect(paths.claudeWorkingDirectory.path == "/Users/p/Library/Application Support/devshout/claude-cwd")
        #expect(paths.glossaryFile.lastPathComponent == "glossary.md")
    }

    @Test func cleanErrorText() {
        #expect(CleanErrorText.describe(.timedOut(after: 20)).contains("20.0 s"))
        #expect(CleanErrorText.describe(.notConnected).contains("devshout-cli connect"))
        #expect(CleanErrorText.describe(.authFailed(message: "OAuth token has expired.")).hasSuffix("Claude said: OAuth token has expired."))
        #expect(CleanErrorText.describe(.processFailed(exitCode: 1, message: "")) == "claude failed with exit code 1.")
        #expect(CleanErrorText.shortName(.rejectedOutput(reason: "x")) == "output rejected")
    }
}

@Suite struct LiveScheduleTests {
    /// Probabilities for a pattern of frames.
    static func frames(_ pattern: [(Int, Float)]) -> [Float] {
        pattern.flatMap { [Float](repeating: $0.1, count: $0.0) }
    }

    static let patterns: [[(Int, Float)]] = [
        // natural cuts
        [(4, 0.02), (20, 0.95), (4, 0.02), (16, 0.95), (6, 0.02)],
        // a long run of speech: forced cuts with overlap
        [(2, 0.02), (130, 0.95), (3, 0.02)],
        // no speech at all
        [(30, 0.02)],
        // speech to the very end
        [(3, 0.02), (25, 0.95)],
        // speech, a long pause, then a long forced run
        [(1, 0.02), (14, 0.95), (12, 0.02), (90, 0.95), (1, 0.4), (20, 0.95)],
    ]

    @Test(arguments: 0..<5)
    func scheduleGivesTheSameChunksAsBatchPlanning(index: Int) {
        let pattern = Self.patterns[index]
        let frame = 4096
        let probabilities: [Float] = Self.frames(pattern)
        let samples = [Float](repeating: 0.1, count: probabilities.count * frame + 1000) // a partial final frame
        let lastProbability: Float = probabilities.last ?? 0
        let all: [Float] = probabilities + [lastProbability]
        let batch = ChunkPlanner.plan(samples: samples, probabilities: all, frameSize: frame, maxChunkDuration: 14.5)
        let schedule = LiveChunkSchedule.schedule(samples: samples, probabilities: all, frameSize: frame,
                                                  maxChunkDuration: 14.5)
        #expect(schedule.map { $0.chunk } == batch)
        let duration = Double(samples.count) / 16_000
        var previous = 0.0
        for item in schedule {
            #expect(item.availableAt >= Double(item.chunk.endSample) / 16_000 - 1e-9)
            #expect(item.availableAt <= duration + 1e-9)
            #expect(item.availableAt >= previous)
            previous = item.availableAt
        }
        if let last = schedule.last, pattern.last?.1 == 0.95 {
            #expect(last.availableAt == duration) // speech to the end: only finish() can close it
        }
    }

    @Test func naturalCutIsAvailableBeforeTheEnd() throws {
        let frame = 4096
        let probabilities = Self.frames([(2, 0.02), (20, 0.95), (6, 0.02), (20, 0.95), (2, 0.02)])
        let samples = [Float](repeating: 0.1, count: probabilities.count * frame)
        let schedule = LiveChunkSchedule.schedule(samples: samples, probabilities: probabilities, frameSize: frame,
                                                  maxChunkDuration: 14.5)
        #expect(schedule.count == 2)
        let first = try #require(schedule.first)
        #expect(first.availableAt < Double(samples.count) / 16_000 - 2)
    }

    @Test func timeline() {
        // Chunk 0 at 5 s takes 1 s; chunk 1 at 5.5 s waits for it and takes 2 s; recording ends at 6 s.
        let t = LiveTimeline.simulate(availableAt: [5, 5.5], durations: [1, 2], recordingDuration: 6, finalisation: 0.1)
        #expect(t.starts == [5, 6])
        #expect(t.finishes == [6, 8])
        #expect(abs(t.textReadyAt - 8.1) < 1e-9)
        #expect(abs(t.tailLatency - 2.1) < 1e-9)
        // Everything done long before the end: only the finalisation remains.
        let early = LiveTimeline.simulate(availableAt: [1], durations: [0.5], recordingDuration: 10, finalisation: 0.05)
        #expect(abs(early.tailLatency - 0.05) < 1e-9)
        // No chunks.
        #expect(LiveTimeline.simulate(availableAt: [], durations: [], recordingDuration: 3).tailLatency == 0)
    }
}

@Suite struct SpikeTranscriberTests {
    static let glossaryText = """
    ## Terms
    - !**CORSIA** — aviation scheme
      - heard: w4
    - **NDC** — national target

    ## Patterns
    - **AB-{n}** — tickets
    """

    /// Speech 1–4.5 s, a pause, speech 6–7.5 s, silence to 8.5 s.
    static let samples = SpikeAudio.make([(1, false), (3.5, true), (1.5, false), (1.5, true), (1, false)])
    static let firstWords = (4...17).map { "w\($0)" }.joined(separator: " ")
    static let secondWords = (24...29).map { "w\($0)" }.joined(separator: " ")

    func transcriber(_ engine: SpikeFakeEngine, vad: SpikeFakeVAD = SpikeFakeVAD()) -> SpikeTranscriber {
        SpikeTranscriber(engine: engine, vad: vad, vadRemainder: { vad.remainder() })
    }

    @Test func wholeModeChunksAndStitches() async throws {
        let engine = SpikeFakeEngine()
        let result = try await transcriber(engine).run(samples: Self.samples, options: SpikeTranscriptionOptions(mode: .whole))
        #expect(result.chunks.count == 2)
        #expect(result.rawText == Self.firstWords + " " + Self.secondWords)
        #expect(result.text == result.rawText)
        #expect(result.timings.tailLatency == nil)
        #expect(result.timings.vad != nil)
        #expect(result.timings.realTimeFactor != nil)
        #expect(result.vocabularyPrompt == nil)
        #expect(engine.contexts.allSatisfy { $0.vocabularyPrompt == nil && $0.previousText == nil })
        #expect(abs(result.audioDuration - 8.5) < 1e-9)
        #expect(result.warnings.isEmpty)
    }

    @Test func glossaryFixesTheText() async throws {
        let engine = SpikeFakeEngine()
        let glossary = Glossary(markdown: Self.glossaryText)
        let result = try await transcriber(engine).run(samples: Self.samples,
                                                        options: SpikeTranscriptionOptions(mode: .whole, glossary: glossary))
        #expect(result.rawText.hasPrefix("w4 w5"))
        #expect(result.text.hasPrefix("CORSIA w5"))
        #expect(result.glossaryFixes == ["w4 → CORSIA"])
        #expect(result.vocabularyPrompt == nil) // Parakeet takes no prompt
    }

    @Test func whisperGetsThePromptAndThePreviousText() async throws {
        let engine = SpikeFakeEngine(id: .whisperLargeV3Turbo, maxChunkDuration: 28)
        let glossary = Glossary(markdown: Self.glossaryText)
        let result = try await transcriber(engine).run(samples: Self.samples,
                                                        options: SpikeTranscriptionOptions(mode: .whole, glossary: glossary))
        let contexts = engine.contexts
        #expect(contexts.count == 2)
        #expect(contexts.allSatisfy { $0.vocabularyPrompt == "CORSIA, NDC" })
        #expect(contexts[0].previousText == nil)
        #expect(contexts[1].previousText == Self.firstWords)
        #expect(result.vocabularyPrompt == "CORSIA, NDC")
        #expect(result.tokenCounter == "approximate")
        #expect(result.vocabularyTokens == ApproximateTokenCounter().count("CORSIA, NDC"))

        let off = SpikeFakeEngine(id: .whisperLargeV3Turbo, maxChunkDuration: 28)
        let noPrompt = try await transcriber(off).run(
            samples: Self.samples, options: SpikeTranscriptionOptions(mode: .whole, glossary: glossary, useVocabularyPrompt: false))
        #expect(off.contexts.allSatisfy { $0.vocabularyPrompt == nil })
        #expect(off.contexts[1].previousText != nil)
        #expect(noPrompt.vocabularyPrompt == nil)
        #expect(noPrompt.text.hasPrefix("CORSIA")) // the TextFixer still runs
    }

    @Test func liveModeReportsTheTailLatency() async throws {
        let engine = SpikeFakeEngine(delay: 0.05)
        let result = try await transcriber(engine).run(samples: Self.samples, options: SpikeTranscriptionOptions(mode: .live))
        let tail = try #require(result.timings.tailLatency)
        #expect(result.timings.tailLatencyMeasured == false)
        #expect(result.chunks.count == 2)
        // Each chunk starts once it exists and the one before is done, and takes what the engine took.
        var busyUntil = 0.0
        for chunk in result.chunks {
            let started = try #require(chunk.startedAt)
            let finished = try #require(chunk.finishedAt)
            #expect(abs(started - max(chunk.availableAt, busyUntil)) < 1e-9)
            #expect(abs(finished - started - chunk.elapsed) < 1e-9)
            busyUntil = finished
        }
        // The first chunk is ready well before the end (a natural cut), the last only when the recording stops.
        #expect(result.chunks[0].availableAt < result.audioDuration - 2)
        #expect(result.chunks[1].availableAt == result.audioDuration)
        let expected = max(result.audioDuration, busyUntil) + result.timings.finalise - result.audioDuration
        #expect(abs(tail - expected) < 1e-9)
        #expect(tail >= result.chunks[1].elapsed)
        #expect(result.timingLines.contains { $0.hasPrefix("Tail latency") && $0.hasSuffix("(simulated)") })
    }

    @Test func liveModeInRealTime() async throws {
        let samples = SpikeAudio.make([(0.2, false), (0.6, true), (0.3, false)])
        let engine = SpikeFakeEngine(delay: 0.02)
        let start = SpikeClock.now()
        let result = try await transcriber(engine).run(samples: samples,
                                                        options: SpikeTranscriptionOptions(mode: .live, realTime: true))
        let wall = SpikeClock.now() - start
        #expect(wall >= result.audioDuration) // waited for the recording to "happen"
        #expect(result.timings.tailLatencyMeasured == true)
        let tail = try #require(result.timings.tailLatency)
        #expect(tail >= 0)
        #expect(tail <= wall - result.audioDuration + 1e-6)
        let chunk = try #require(result.chunks.first)
        #expect(try #require(chunk.startedAt) >= chunk.availableAt - 1e-3)
    }

    @Test func singleModeSendsTheWholeFile() async throws {
        let engine = SpikeFakeEngine()
        let result = try await SpikeTranscriber(engine: engine, vad: nil)
            .run(samples: Self.samples, options: SpikeTranscriptionOptions(mode: .single))
        #expect(result.chunks.count == 1)
        #expect(result.chunks[0].start == 0 && abs(result.chunks[0].end - 8.5) < 1e-9)
        #expect(result.timings.vad == nil)
        #expect(result.rawText.hasPrefix("w4"))
    }

    @Test func silenceGivesAWarning() async throws {
        let result = try await transcriber(SpikeFakeEngine())
            .run(samples: SpikeAudio.make([(3, false)]), options: SpikeTranscriptionOptions(mode: .whole))
        #expect(result.chunks.isEmpty)
        #expect(result.text.isEmpty)
        #expect(result.warnings == ["No speech was detected."])
    }

    @Test func chunkedModesNeedTheVAD() async {
        await #expect(throws: SpikeError.missingVAD) {
            _ = try await SpikeTranscriber(engine: SpikeFakeEngine(), vad: nil)
                .run(samples: Self.samples, options: SpikeTranscriptionOptions(mode: .whole))
        }
    }

    @Test func prepareIsTimed() async throws {
        let engine = SpikeFakeEngine()
        let seconds = try await transcriber(engine).prepareEngine(progress: { _ in })
        #expect(seconds >= 0)
        #expect(engine.prepared == 1)
    }

    @Test func jsonRoundTrips() async throws {
        let result = try await transcriber(SpikeFakeEngine()).run(samples: Self.samples,
                                                                  options: SpikeTranscriptionOptions(mode: .live))
        let json = try result.jsonString()
        #expect(json.contains("\"engine\" : \"parakeet-tdt-0.6b-v3\""))
        #expect(json.contains("\"mode\" : \"live\""))
        let decoded = try JSONDecoder().decode(SpikeTranscriptionResult.self, from: Data(json.utf8))
        #expect(decoded == result)
    }
}

@Suite struct SpikeTextTests {
    static let token = "sk-ant-oat01-" + String(repeating: "aB3_-", count: 18) + "xyzAA"

    @Test func pastedTokens() throws {
        #expect(try SpikeTokenInput.token(from: "  \(Self.token)\n") == Self.token)
        #expect(try SpikeTokenInput.token(from: "export CLAUDE_CODE_OAUTH_TOKEN=\(Self.token)") == Self.token)
        #expect(throws: SpikeError.self) { try SpikeTokenInput.token(from: "sk-ant-api03-" + String(repeating: "x", count: 60)) }
        #expect(throws: SpikeError.self) { try SpikeTokenInput.token(from: "") }
        #expect(throws: SpikeError.self) { try SpikeTokenInput.token(from: "hello") }
    }

    @Test func wholeSetupTokenOutput() throws {
        let pasted = """
        ✓ Long-lived authentication token created successfully!

        Your OAuth token (valid for 1 year):

        \(Self.token)

        Store this token securely. You won't be able to see it again.
        """
        #expect(try SpikeTokenInput.token(from: pasted) == Self.token)
    }

    @Test func creationDay() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(SpikeTokenInput.date(fromDay: "2026-11-10", timeZone: utc))
        #expect(date.timeIntervalSince1970 == 1_794_268_800)
        #expect(SpikeTokenInput.date(fromDay: "10/11/2026") == nil)
        #expect(SpikeTokenInput.date(fromDay: "2026-13-40") == nil)
    }

    @Test func glossarySummary() {
        let summary = GlossarySummary.render(Glossary(markdown: SpikeTranscriberTests.glossaryText + """

        ## People
        - **Siobhán Murphy** — heard: shiv on

        ## Style
        Use British English.
        """))
        #expect(summary.contains("Found: 2 terms, 1 person, 1 pattern"))
        #expect(summary.contains("## Terms [terms]: 2 entries, 1 known mishearing"))
        #expect(summary.contains("Pinned (top of Whisper's list): CORSIA"))
        #expect(summary.contains("  AB-{n} — tickets"))
        #expect(summary.contains("w4 → CORSIA"))
        #expect(summary.contains("Style notes: 1 lines") || summary.contains("Style notes: 1 line"))
        #expect(GlossarySummary.render(Glossary(markdown: GlossaryFile.starterTemplate)).contains("nothing devshout would use"))
    }

    @Test func connectionReport() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let created = Date(timeIntervalSince1970: 1_794_268_800) // 10 November 2026
        let installation = ClaudeInstallation(url: URL(fileURLWithPath: "/Users/p/.local/bin/claude"),
                                              version: ClaudeVersion(2, 1, 322))
        let ok = SpikeConnectionReport.render(installation: installation, installationError: nil,
                                              credential: ClaudeCredential(token: Self.token, createdAt: created),
                                              source: .keychain, keychainError: nil, authFailure: nil,
                                              homeDirectory: "/Users/p", now: created.addingTimeInterval(86_400),
                                              timeZone: utc)
        #expect(ok.hasPrefix("Status: Connected\n"))
        #expect(ok.contains("Claude Code: Claude Code 2.1.322 (~/.local/bin/claude)"))
        #expect(ok.contains("Token: sk-ant-oat01-…yzAA, from Keychain"))
        #expect(ok.contains("Created: 10 November 2026 · expires: 10 November 2027"))
        #expect(ok.contains("Health: OK, 364 days left"))
        #expect(!ok.contains(Self.token))

        let none = SpikeConnectionReport.render(installation: nil, installationError: "not on PATH", credential: nil,
                                                source: nil, keychainError: nil, authFailure: nil, homeDirectory: "/Users/p")
        #expect(none.hasPrefix("Status: Claude Code isn't installed"))
        #expect(none.contains("Token: none stored"))

        let soon = SpikeConnectionReport.render(installation: installation, installationError: nil,
                                                credential: ClaudeCredential(token: Self.token, createdAt: created),
                                                source: .keychain, keychainError: nil, authFailure: nil,
                                                homeDirectory: "/Users/p", now: created.addingTimeInterval(355 * 86_400),
                                                timeZone: utc)
        #expect(soon.contains("Health: expiring in 10 days"))
    }
}
