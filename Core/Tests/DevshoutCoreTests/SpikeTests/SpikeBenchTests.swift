import Foundation
import Testing
@testable import DevshoutCore

/// Collects log lines and calls from @Sendable closures.
final class SpikeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func add(_ line: String) { lock.lock(); _lines.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
}

@Suite struct SpikeBenchTests {
    static let sentences = """
    # Sentences
    - s01: Check the CORSIA flag on AB-1234.
    - s02: Map each NDC target.
    - s03: A third one.
    """

    static let outline = """
    ### 1. Flag
    - keywords: CORSIA ; flag
    ### 2. Ticket
    - keywords: AB-1234
    - retracted: AB-1243
    """

    static let glossary = """
    ## Terms
    - **CORSIA** — scheme
    - **NDC** — target
    """

    /// s01: audio + reference + superwhisper; s02: audio, no reference; s03: nothing; ramble: audio + reference.
    func makeCorpus() throws -> (SpikeTempDir, BenchCorpus) {
        let dir = try SpikeTempDir("bench")
        try dir.write(Self.sentences, to: "sentences.md")
        try dir.write(Self.outline, to: "ramble-outline.md")
        try dir.write(Self.glossary, to: "glossary.sample.md")
        for id in ["s01", "s02", "ramble"] { try dir.write("RIFF", to: "audio/\(id).wav") }
        try dir.write("Check the CORSIA flag on AB-1234.\n", to: "references/s01.txt")
        try dir.write("Check the CORSIA flag and AB-1234, not AB-1243.\n", to: "references/ramble.txt")
        try dir.write("check the corsia flag on AB-1234", to: "superwhisper/s01.txt")
        return (dir, try BenchCorpus.load(directory: dir.url))
    }

    /// The fake engine "hears" the reference, with CORSIA in lower case for Whisper without a prompt.
    func dependencies(log: SpikeRecorder, cleanFails: CleanError? = nil) -> SpikeBenchDependencies {
        SpikeBenchDependencies(
            prepare: { engine in
                log.add("prepare \(engine.rawValue)")
                return (1.5, false)
            },
            transcribe: { url, run in
                log.add("transcribe \(url.lastPathComponent) \(run.label)")
                let id = url.deletingPathExtension().lastPathComponent
                let reference = try String(contentsOf: url.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("references/\(id).txt"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let text = run.useVocabularyPrompt ? reference : reference.replacingOccurrences(of: "CORSIA", with: "corsia")
                return SpikeTranscriptionResult(engine: run.engine, mode: .live, audioDuration: 3, text: text,
                                                rawText: text, chunks: [],
                                                timings: SpikeTranscriptionTimings(transcribe: 0.25, tailLatency: 0.1))
            },
            unload: { engine in log.add("unload \(engine.rawValue)") },
            clean: { text, mode in
                log.add("clean \(mode.id.rawValue) \(mode.claudeModel)")
                if let cleanFails { throw cleanFails }
                return CleanResult(text: text.replacingOccurrences(of: ", not AB-1243", with: ""), model: mode.claudeModel,
                                   elapsed: 2)
            },
            log: { _ in })
    }

    @Test func parsesEnginesAndModes() throws {
        #expect(try SpikeBenchEngine.parse("parakeet,whisper").map(\.label) == ["parakeet", "whisper"])
        #expect(try SpikeBenchEngine.parse("whisper,parakeet", whisperPrompt: .both).map(\.label)
                == ["whisper", "whisper-noprompt", "parakeet"])
        #expect(try SpikeBenchEngine.parse("whisper", whisperPrompt: .off).map(\.label) == ["whisper-noprompt"])
        #expect(throws: SpikeError.unknownEngine("vosk")) { try SpikeBenchEngine.parse("parakeet,vosk") }
        #expect(try SpikeBenchOptions.parseModes("raw, Tidy,raw") == [.raw, .tidy])
        #expect(throws: SpikeError.unknownMode("fancy")) { try SpikeBenchOptions.parseModes("fancy") }
    }

    @Test func runsTheMatrixAndScoresIt() async throws {
        let (dir, corpus) = try makeCorpus()
        defer { dir.remove() }
        let log = SpikeRecorder()
        let options = SpikeBenchOptions(engines: try SpikeBenchEngine.parse("parakeet,whisper", whisperPrompt: .both),
                                        modes: [.raw, .tidy, .structure])
        let result = await SpikeBench.run(corpus: corpus, glossaryTerms: corpus.glossaryTerms, options: options,
                                          dependencies: dependencies(log: log))

        #expect(result.notes.contains("s02: skipped, no references/s02.txt."))
        #expect(result.notes.contains("s03: skipped, no audio/s03.wav and no references/s03.txt."))
        // 3 engine runs × 2 samples × 3 modes, plus superwhisper for s01.
        #expect(result.rows.count == 19)
        #expect(result.details.count == 19)
        let raw = try #require(result.rows.first { $0.sample == "s01" && $0.engine == "parakeet" && $0.mode == "raw" })
        #expect(raw.wer == 0)
        #expect(raw.termHits == 2 && raw.termTotal == 2) // CORSIA and the ticket from the reference
        #expect(raw.timings.modelLoad == 1.5)
        #expect(raw.timings.transcribe == 0.25 && raw.timings.tailLatency == 0.1)
        #expect(raw.pointsTotal == nil)
        // The model load is only on the engine's first row.
        #expect(result.rows.filter { $0.engine == "parakeet" && $0.timings.modelLoad != nil }.count == 1)

        let noPrompt = try #require(result.rows.first { $0.sample == "s01" && $0.engine == "whisper-noprompt" && $0.mode == "raw" })
        #expect(noPrompt.termHits == 1)

        let tidy = try #require(result.rows.first { $0.sample == "ramble" && $0.engine == "parakeet" && $0.mode == "tidy" })
        #expect(tidy.model == "haiku")
        #expect(tidy.timings.claudeTotal == 2)
        #expect(tidy.pointsCovered == 2 && tidy.pointsTotal == 2)
        let rawRamble = try #require(result.details.first { $0.row.sample == "ramble" && $0.row.engine == "parakeet" && $0.row.mode == "raw" })
        #expect(rawRamble.retractedFound == ["2. “AB-1243”"])
        let structure = try #require(result.rows.first { $0.mode == "structure" })
        #expect(structure.model == "sonnet")

        let superwhisper = try #require(result.rows.first { $0.engine == "superwhisper" })
        #expect(superwhisper.sample == "s01" && superwhisper.mode == "saved")
        #expect(superwhisper.termHits == 1) // "corsia" is not "CORSIA"

        let lines = log.lines
        #expect(lines.filter { $0.hasPrefix("prepare") } == ["prepare parakeet-tdt-0.6b-v3", "prepare whisper-large-v3-turbo",
                                                             "prepare whisper-large-v3-turbo"])
        #expect(lines.filter { $0.hasPrefix("unload") }.count == 3)
        #expect(!lines.contains { $0.contains("s02.wav") })
    }

    @Test func stopsAskingClaudeWhenItCannotWork() async throws {
        let (dir, corpus) = try makeCorpus()
        defer { dir.remove() }
        let log = SpikeRecorder()
        let options = SpikeBenchOptions(engines: [SpikeBenchEngine(engine: .parakeetV3)], modes: [.raw, .tidy, .structure],
                                        runs: 2)
        let result = await SpikeBench.run(corpus: corpus, glossaryTerms: corpus.glossaryTerms, options: options,
                                          dependencies: dependencies(log: log, cleanFails: .notConnected))
        #expect(log.lines.filter { $0.hasPrefix("clean") }.count == 1)
        #expect(result.notes.contains { $0.contains("clean-up failed") && $0.contains("devshout-cli connect") })
        #expect(result.notes.filter { $0.hasSuffix("not run (not connected).") }.count == 7)
        // Two runs of two samples give four raw rows; the failed clean-up has a row without scores.
        #expect(result.rows.filter { $0.mode == "raw" }.count == 4)
        let failed = try #require(result.rows.first { $0.mode == "tidy" })
        #expect(failed.wer == nil && failed.timings.claudeTotal != nil)
    }

    @Test func nothingToRun() async throws {
        let dir = try SpikeTempDir("bench-empty")
        defer { dir.remove() }
        try dir.write(Self.sentences, to: "sentences.md")
        try dir.write(Self.outline, to: "ramble-outline.md")
        let corpus = try BenchCorpus.load(directory: dir.url)
        let log = SpikeRecorder()
        let result = await SpikeBench.run(corpus: corpus, glossaryTerms: [], options: SpikeBenchOptions(
            engines: [SpikeBenchEngine(engine: .parakeetV3)], modes: [.raw]), dependencies: dependencies(log: log))
        #expect(result.rows.isEmpty)
        #expect(result.notes.last == "No sample has both a recording and a reference, so no engine ran.")
        #expect(log.lines.isEmpty)
    }

    @Test func writesTheReport() async throws {
        let (dir, corpus) = try makeCorpus()
        defer { dir.remove() }
        let result = await SpikeBench.run(corpus: corpus, glossaryTerms: corpus.glossaryTerms,
                                          options: SpikeBenchOptions(engines: [SpikeBenchEngine(engine: .parakeetV3)],
                                                                     modes: [.raw, .tidy]),
                                          dependencies: dependencies(log: SpikeRecorder()))
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_794_321_120) // 2026-11-10 14:32 UTC
        #expect(SpikeBenchReportWriter.fileStem(date: date, timeZone: utc) == "2026-11-10-1432")

        let markdown = SpikeBenchReportWriter.markdown(result: result, title: "devshout bench", settings: ["Engines: parakeet"])
        #expect(markdown.hasPrefix("# devshout bench\n\n- Engines: parakeet\n\n## Results"))
        #expect(markdown.contains("## Summary"))
        #expect(markdown.contains("## Notes\n\n- s02: skipped"))
        #expect(markdown.contains("### ramble · parakeet · tidy · haiku"))
        #expect(markdown.contains("Corrected-away phrases still there: 2. “AB-1243”"))
        #expect(markdown.contains("```text\nCheck the CORSIA flag on AB-1234.\n```"))

        let out = dir.url.appendingPathComponent("results")
        let first = try SpikeBenchReportWriter.write(result: result, title: "t", settings: [], to: out, date: date)
        let second = try SpikeBenchReportWriter.write(result: result, title: "t", settings: [], to: out, date: date)
        #expect(first.markdown.lastPathComponent.hasSuffix(".md"))
        #expect(second.markdown.deletingPathExtension().lastPathComponent
                == first.markdown.deletingPathExtension().lastPathComponent + "-2")
        let csv = try String(contentsOf: first.csv, encoding: .utf8)
        #expect(csv.hasPrefix("sample,engine,mode,model,wer"))
        #expect(csv.split(separator: "\n").count == result.rows.count + 1)
    }
}

@Suite(.serialized) struct ClaudeProbeTests {
    func fakeInstallation(mode: String, extra: [String: String] = [:]) throws -> (SpikeTempDir, ClaudeInstallation, SpikePaths) {
        let dir = try SpikeTempDir("probe")
        let paths = SpikePaths(devshoutFolder: dir.url.appendingPathComponent("devshout"))
        let bin = dir.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // Clean-ups read their settings from CLAUDE_CONFIG_DIR, `--version` from $HOME/.claude.
        let claude = try ClaudeTestSupport.fakeClaude(mode: mode, extraEnvironment: extra, in: bin,
                                                      settingsDirectory: paths.claudeConfigDirectory)
        return (dir, ClaudeInstallation(url: claude, version: ClaudeVersion(2, 1, 300)), paths)
    }

    @Test func timesVersionRuns() async throws {
        let (dir, installation, _) = try fakeInstallation(mode: "ok-echo")
        defer { dir.remove() }
        let request = ClaudeProbe.versionRequest(for: installation, home: dir.url.path)
        #expect(request.arguments == ["--version"])
        #expect(request.environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        let (times, failures) = await ClaudeProbe.time(request, runs: 3)
        #expect(times.count == 3)
        #expect(failures.isEmpty)
    }

    @Test func reportsFailedRuns() async throws {
        let dir = try SpikeTempDir("probe-missing")
        defer { dir.remove() }
        let missing = ClaudeInstallation(url: dir.url.appendingPathComponent("nope"), version: ClaudeVersion(2, 1, 300))
        let (times, failures) = await ClaudeProbe.time(ClaudeProbe.versionRequest(for: missing, home: dir.url.path), runs: 2)
        #expect(times.isEmpty)
        #expect(failures.count == 2)
    }

    @Test func cleanUpRequestIsTheAppsInvocation() throws {
        let (dir, installation, paths) = try fakeInstallation(mode: "ok-echo")
        defer { dir.remove() }
        let credential = ClaudeTestSupport.credential
        let (request, promptFile) = try ClaudeProbe.cleanUpRequest(installation: installation, credential: credential,
                                                                   mode: ClaudeProbe.probeMode(), paths: paths,
                                                                   host: ClaudeTestSupport.host,
                                                                   temporaryDirectory: dir.url.appendingPathComponent("tmp"))
        defer { try? FileManager.default.removeItem(at: promptFile) }
        let expected = ClaudeInvocation(executable: installation.url, model: "haiku", systemPrompt: .file(promptFile),
                                        stdin: PromptBuilder.userMessage(transcript: ClaudeProbe.probeSentence),
                                        credential: credential, configDirectory: paths.claudeConfigDirectory,
                                        workingDirectory: paths.claudeWorkingDirectory, host: ClaudeTestSupport.host,
                                        timeout: 60)
        #expect(request == expected.processRequest)
        #expect(!request.arguments.contains("--bare"))
        #expect(FileManager.default.fileExists(atPath: promptFile.path))
        #expect(FileManager.default.fileExists(atPath: paths.claudeWorkingDirectory.path))
    }

    @Test func prewarmedProcessWaitsForItsInput() async throws {
        let (dir, installation, paths) = try fakeInstallation(mode: "ok-echo")
        defer { dir.remove() }
        let (request, promptFile) = try ClaudeProbe.cleanUpRequest(installation: installation,
                                                                   credential: ClaudeTestSupport.credential,
                                                                   mode: ClaudeProbe.probeMode(), paths: paths,
                                                                   host: ClaudeTestSupport.host,
                                                                   temporaryDirectory: dir.url.appendingPathComponent("tmp"))
        defer { try? FileManager.default.removeItem(at: promptFile) }
        let child = try PrewarmedProcess.start(request)
        try await Task.sleep(nanoseconds: 300_000_000)
        let run = await child.finish(stdin: Data(PromptBuilder.userMessage(transcript: "hello there").utf8))
        #expect(run.result.exitCode == 0)
        #expect(!run.result.timedOut)
        #expect(run.writtenAt >= 0.3)
        #expect(run.afterWrite < run.result.elapsed)
        #expect(!run.outputBeforeWrite)
        #expect(run.firstByteAfterWrite != nil)
        #expect(try ClaudeResultParser.interpret(run.result).get() == "hello there")
    }

    @Test func prewarmedProcessTimesOut() async throws {
        let (dir, installation, paths) = try fakeInstallation(mode: "hang")
        defer { dir.remove() }
        let (request, promptFile) = try ClaudeProbe.cleanUpRequest(installation: installation,
                                                                   credential: ClaudeTestSupport.credential,
                                                                   mode: ClaudeProbe.probeMode(timeout: 0.5), paths: paths,
                                                                   host: ClaudeTestSupport.host,
                                                                   temporaryDirectory: dir.url.appendingPathComponent("tmp"))
        defer { try? FileManager.default.removeItem(at: promptFile) }
        let child = try PrewarmedProcess.start(request, killGracePeriod: 0.5)
        let run = await child.finish(stdin: Data("<transcript>\nhi\n</transcript>\n".utf8))
        #expect(run.result.timedOut)
        #expect(run.afterWrite < 5)
    }

    @Test func prewarmedLaunchFailure() throws {
        let request = ProcessRequest(executable: URL(fileURLWithPath: "/nonexistent/claude"), arguments: [],
                                     environment: [:])
        #expect(throws: ProcessRunnerError.self) { _ = try PrewarmedProcess.start(request) }
    }
}
