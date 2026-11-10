// devshout-cli bench: every recording in bench/audio × engine × mode, scored against bench/references, written to
// bench/results/<yyyy-mm-dd-hhmm>.md and .csv.
//
// The matrix, scoring and report are Core's SpikeBench (tested on Linux with fakes); this file plugs in the real
// engines, Silero VAD and ClaudeCLICleaner.
// Unsure on macOS (written on Linux, type-checked there against stand-ins for DevshoutMac, never run on a Mac):
// - `sysctlbyname("hw.model")` for the machine name in the report (falls back to "this Mac").
#if canImport(Darwin)
import Darwin
#endif
import ArgumentParser
import DevshoutCore
import DevshoutMac
import Foundation

struct BenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Run the Phase 0 benchmark and write bench/results/<date>.md and .csv.",
        discussion: """
        For each bench/audio/<id>.wav that has bench/references/<id>.txt: transcribes it with each engine (live \
        mode, which gives both the transcription time and the tail latency), cleans the text up in each Claude \
        mode, and scores every result: WER, glossary terms spelled exactly right, and (ramble only) the outline's \
        points. bench/superwhisper/<id>.txt, when present, is scored as engine "superwhisper". Missing files are \
        skipped with a note in the report.
        """
    )

    @Option(name: [.customLong("dir"), .customLong("set")], help: "The bench folder.")
    var dir = "bench"

    @Option(help: "Comma-separated: parakeet, whisper.")
    var engines = "parakeet,whisper"

    @Option(help: "Comma-separated: raw, tidy, structure.")
    var modes = "raw,tidy,structure"

    @Option(help: "Runs per sample, engine and mode (the report averages them).")
    var runs = 1

    @Option(help: "Glossary for Whisper's prompt, the glossary fixes, Claude and the term score. Default: the bench folder's glossary.md, else glossary.sample.md.")
    var glossary: String?

    @Option(name: .customLong("whisper-prompt"),
            help: "Whisper with the glossary prompt (on), without it (off), or both, as engines whisper and whisper-noprompt.")
    var whisperPrompt: WhisperPromptChoice = .on

    @Option(name: .customLong("tidy-model"), help: "Claude model for Tidy.")
    var tidyModel = "haiku"

    @Option(name: .customLong("structure-model"), help: "Claude model for Structure.")
    var structureModel = "sonnet"

    @Option(help: "Claude timeout in seconds for both modes. Default: 20 for Tidy, 45 for Structure.")
    var timeout: Double?

    @Option(help: "Only these samples, comma-separated (e.g. s01,ramble).")
    var samples: String?

    @Option(name: .customLong("chunk-config"), help: "A JSON file with ChunkPlannerConfig values to try.")
    var chunkConfig: String?

    func validate() throws {
        guard runs >= 1 else { throw ValidationError("--runs must be at least 1.") }
        if let timeout, !(timeout > 0) { throw ValidationError("--timeout must be more than 0.") }
    }

    mutating func run() async throws {
        let directory = Files.url(dir)
        let corpus: BenchCorpus
        do {
            corpus = try BenchCorpus.load(directory: directory)
        } catch {
            throw CLIError("Couldn't read the bench folder \(directory.path): \(error)")
        }
        let engineRuns = try SpikeBenchEngine.parse(engines, whisperPrompt: whisperPrompt.value)
        let modeList = try SpikeBenchOptions.parseModes(modes)
        let config = try Files.chunkConfig(chunkConfig)

        // The glossary: --glossary, else the corpus's own.
        let glossaryURL: URL?
        if let glossary {
            glossaryURL = try Files.existing(glossary, what: "glossary")
        } else {
            glossaryURL = corpus.glossaryURL
        }
        let glossaryText = try glossaryURL.map { try GlossaryFile(url: $0).loadText() }
        let parsedGlossary = glossaryText.map(GlossaryParser.parse)
        let glossaryTerms = glossaryText.map(BenchGlossaryTerms.terms(fromMarkdown:)) ?? []
        let claudeGlossary = parsedGlossary.map(GlossaryRenderer.forClaude) ?? ""
        if glossaryURL == nil { Console.error("Warning: no glossary, so the term scores only count ticket IDs.") }

        var configs = ModeConfig.defaults
        configs[.tidy] = ModeConfig(id: .tidy, claudeModel: tidyModel, timeout: timeout ?? (configs[.tidy]?.timeout ?? 20))
        configs[.structure] = ModeConfig(id: .structure, claudeModel: structureModel,
                                         timeout: timeout ?? (configs[.structure]?.timeout ?? 45))
        let onlySamples = samples.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        let options = SpikeBenchOptions(engines: engineRuns, modes: modeList, runs: runs, modeConfigs: configs,
                                        onlySamples: onlySamples)

        var claudeVersion = "not used"
        if modeList.contains(where: \.usesClaude) {
            let found = await ClaudeSetup.locate()
            claudeVersion = found.installation.map { "Claude Code \($0.displayVersion)" } ?? "not found"
            if let error = found.error { Console.error("Warning: \(error). Tidy and Structure rows will fail.") }
            if Credentials.current().credential == nil {
                Console.error("Warning: no Claude token (run devshout-cli connect). Tidy and Structure rows will fail.")
            }
        }

        let host = EngineHost()
        let cleaner = ClaudeSetup.makeCleaner()
        let started = Date()
        let dependencies = SpikeBenchDependencies(
            prepare: { id in
                let load = try await host.prepare(id)
                _ = try await host.prepareVAD()
                return load
            },
            transcribe: { url, run in
                let audio = try readAudio(url)
                let options = SpikeTranscriptionOptions(mode: .live, glossary: parsedGlossary,
                                                        useVocabularyPrompt: run.useVocabularyPrompt,
                                                        plannerConfig: config)
                return try await host.transcribe(samples: audio, engine: run.engine, options: options,
                                                 audioFile: url.path)
            },
            unload: { id in await host.unload(id) },
            clean: { text, mode in try await cleaner.clean(text, mode: mode, glossary: claudeGlossary) },
            log: { Console.error($0) })

        let result = await SpikeBench.run(corpus: corpus, glossaryTerms: glossaryTerms, options: options,
                                          dependencies: dependencies)
        await host.unloadAll()

        let stem = SpikeBenchReportWriter.fileStem(date: started)
        var settings = [
            "Run: \(stem), took \(SpikeFormat.seconds(Date().timeIntervalSince(started))) on \(Self.machine()), "
                + "\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Engines: " + engineRuns.map { "\($0.label) (\($0.engine.displayName))" }.joined(separator: ", "),
            "Modes: " + modeList.map { mode -> String in
                guard mode.usesClaude, let c = configs[mode] else { return mode.rawValue }
                return "\(mode.rawValue) (\(c.claudeModel), timeout \(SpikeFormat.seconds(c.timeout)))"
            }.joined(separator: ", "),
            "Runs: \(runs) per sample, engine and mode",
            "Glossary: \(glossaryURL?.lastPathComponent ?? "none") (\(glossaryTerms.count) terms scored, plus ticket IDs in each reference)",
            "Claude: \(claudeVersion)",
            "Transcription: VAD + chunk planner, chunks transcribed in order; Tail = simulated wait after the end "
                + "of the recording if the chunks had been transcribed while recording (Load is on each engine's first row)",
            "Claude 1st byte is not measured (claude -p --output-format json writes its answer at the end); see "
                + "`devshout-cli claude-probe` for start-up and pre-warm timings",
        ]
        if config != .default { settings.append("Chunk config: \(Self.describe(config))") }

        let written: (markdown: URL, csv: URL)
        do {
            written = try SpikeBenchReportWriter.write(result: result, title: "devshout bench \(stem)",
                                                       settings: settings,
                                                       to: directory.appendingPathComponent("results"), date: started)
        } catch {
            throw CLIError("Couldn't write the results: \(error.localizedDescription)")
        }
        Console.error("")
        for note in result.notes { Console.error("Note: \(note)") }
        Console.error("\(result.rows.count) rows.")
        Console.out(written.markdown.path)
        Console.out(written.csv.path)
    }

    static func describe(_ config: ChunkPlannerConfig) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(config)).map { String(decoding: $0, as: UTF8.self) } ?? "custom"
    }

    /// "MacBookPro18,1" (an M1 Pro), or "this Mac".
    static func machine() -> String {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "this Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "this Mac" }
        return String(cString: bytes)
        #else
        return "this machine"
        #endif
    }
}
