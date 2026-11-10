import Foundation

/// One engine configuration the bench runs: an engine, and whether Whisper gets the glossary prompt.
public struct SpikeBenchEngine: Sendable, Hashable {
    public var engine: EngineID
    public var useVocabularyPrompt: Bool
    /// The name in the report's Engine column: "parakeet", "whisper", "whisper-noprompt".
    public var label: String

    public init(engine: EngineID, useVocabularyPrompt: Bool = true, label: String? = nil) {
        self.engine = engine
        self.useVocabularyPrompt = useVocabularyPrompt
        self.label = label ?? SpikeBenchEngine.defaultLabel(engine: engine, useVocabularyPrompt: useVocabularyPrompt)
    }

    public static func defaultLabel(engine: EngineID, useVocabularyPrompt: Bool) -> String {
        switch engine {
        case .parakeetV3: "parakeet"
        case .whisperLargeV3Turbo: useVocabularyPrompt ? "whisper" : "whisper-noprompt"
        }
    }

    /// "parakeet" / "whisper" (also the full engine ids) → the engine.
    public static func engineID(named name: String) -> EngineID? {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "parakeet", EngineID.parakeetV3.rawValue: .parakeetV3
        case "whisper", EngineID.whisperLargeV3Turbo.rawValue: .whisperLargeV3Turbo
        default: nil
        }
    }

    /// Whisper with the prompt, without it, or both (to see whether the prompt helps).
    public enum WhisperPrompt: String, Sendable, CaseIterable { case on, off, both }

    /// The engine list for `--engines parakeet,whisper` and `--whisper-prompt`.
    public static func parse(_ list: String, whisperPrompt: WhisperPrompt = .on) throws -> [SpikeBenchEngine] {
        var out: [SpikeBenchEngine] = []
        for name in list.split(separator: ",").map(String.init) where !name.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let id = engineID(named: name) else { throw SpikeError.unknownEngine(name) }
            var runs: [SpikeBenchEngine] = []
            if id.supportsVocabularyPrompt {
                if whisperPrompt != .off { runs.append(SpikeBenchEngine(engine: id, useVocabularyPrompt: true)) }
                if whisperPrompt != .on { runs.append(SpikeBenchEngine(engine: id, useVocabularyPrompt: false)) }
            } else {
                runs.append(SpikeBenchEngine(engine: id))
            }
            for run in runs where !out.contains(run) { out.append(run) }
        }
        guard !out.isEmpty else { throw SpikeError.invalidInput("No engines given. Use --engines parakeet,whisper.") }
        return out
    }
}

public struct SpikeBenchOptions: Sendable {
    public var engines: [SpikeBenchEngine]
    public var modes: [ModeID]
    public var runs: Int
    /// The Claude settings per mode (model and timeout).
    public var modeConfigs: [ModeID: ModeConfig]
    /// Only these sample ids, when set.
    public var onlySamples: [String]?

    public init(engines: [SpikeBenchEngine], modes: [ModeID], runs: Int = 1,
                modeConfigs: [ModeID: ModeConfig] = ModeConfig.defaults, onlySamples: [String]? = nil) {
        self.engines = engines
        self.modes = modes
        self.runs = max(1, runs)
        self.modeConfigs = modeConfigs
        self.onlySamples = onlySamples
    }

    /// "raw,tidy,structure" → modes, in the order given, without repeats.
    public static func parseModes(_ list: String) throws -> [ModeID] {
        var out: [ModeID] = []
        for name in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() })
            where !name.isEmpty {
            guard let mode = ModeID(rawValue: name) else { throw SpikeError.unknownMode(name) }
            if !out.contains(mode) { out.append(mode) }
        }
        guard !out.isEmpty else { throw SpikeError.invalidInput("No modes given. Use --modes raw,tidy,structure.") }
        return out
    }
}

/// What the bench needs from the outside world, as closures so the bench is tested with fakes.
public struct SpikeBenchDependencies: Sendable {
    /// Prepares (downloads and loads) an engine; returns the time it took and whether it downloaded.
    public var prepare: @Sendable (EngineID) async throws -> (seconds: TimeInterval, downloaded: Bool)
    /// Transcribes one file in live mode with the bench glossary (`SpikeTranscriber.run`).
    public var transcribe: @Sendable (URL, SpikeBenchEngine) async throws -> SpikeTranscriptionResult
    public var unload: @Sendable (EngineID) async -> Void
    /// Clean-up with Claude (`ClaudeCLICleaner.clean` with the bench glossary). Throws `CleanError`.
    public var clean: @Sendable (String, ModeConfig) async throws -> CleanResult
    /// Progress lines for the terminal.
    public var log: @Sendable (String) -> Void

    public init(prepare: @escaping @Sendable (EngineID) async throws -> (seconds: TimeInterval, downloaded: Bool),
                transcribe: @escaping @Sendable (URL, SpikeBenchEngine) async throws -> SpikeTranscriptionResult,
                unload: @escaping @Sendable (EngineID) async -> Void,
                clean: @escaping @Sendable (String, ModeConfig) async throws -> CleanResult,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.prepare = prepare
        self.transcribe = transcribe
        self.unload = unload
        self.clean = clean
        self.log = log
    }
}

/// The text and scoring details behind one report row, for the Details section.
public struct SpikeBenchDetail: Sendable, Hashable {
    public var row: BenchRow
    public var text: String
    public var werErrors: String
    public var missedTerms: [String]
    public var missingPoints: [String]
    public var retractedFound: [String]
    public var warnings: [String]

    public init(row: BenchRow, text: String, werErrors: String = "", missedTerms: [String] = [],
                missingPoints: [String] = [], retractedFound: [String] = [], warnings: [String] = []) {
        self.row = row
        self.text = text
        self.werErrors = werErrors
        self.missedTerms = missedTerms
        self.missingPoints = missingPoints
        self.retractedFound = retractedFound
        self.warnings = warnings
    }
}

public struct SpikeBenchResult: Sendable {
    public var rows: [BenchRow]
    public var details: [SpikeBenchDetail]
    /// Skipped files and failures, in order.
    public var notes: [String]

    public init(rows: [BenchRow] = [], details: [SpikeBenchDetail] = [], notes: [String] = []) {
        self.rows = rows
        self.details = details
        self.notes = notes
    }
}

/// `devshout-cli bench`: every sample × engine × mode, scored with the Bench metrics (PLAN §9, Phase 0).
///
/// Each engine run transcribes a sample once in live mode, which gives both the whole-file transcription time and the
/// tail latency: live mode uses exactly the chunks and order of whole mode (`ChunkPlanner` streaming gives what
/// batch planning gives), so a second pass would only repeat the work. Tidy and Structure clean up that run's text
/// and add Claude's time to the row. superwhisper's saved text is scored once per sample.
public enum SpikeBench {
    public static func run(corpus: BenchCorpus, glossaryTerms: [String], options: SpikeBenchOptions,
                           dependencies deps: SpikeBenchDependencies) async -> SpikeBenchResult {
        var result = SpikeBenchResult()
        let samples = corpus.samples.filter { options.onlySamples?.contains($0.id) ?? true }

        // Which samples can run, and why the others can't.
        var runnable: [(sample: BenchSample, audio: URL, reference: String)] = []
        for sample in samples {
            let reference: String?
            do {
                reference = try corpus.reference(for: sample)
            } catch {
                result.notes.append("\(sample.id): skipped, couldn't read references/\(sample.id).txt (\(error.localizedDescription)).")
                continue
            }
            switch (sample.audioURL, reference) {
            case (nil, nil):
                result.notes.append("\(sample.id): skipped, no audio/\(sample.id).wav and no references/\(sample.id).txt.")
            case (nil, _):
                result.notes.append("\(sample.id): skipped, no audio/\(sample.id).wav.")
            case (_, nil):
                result.notes.append("\(sample.id): skipped, no references/\(sample.id).txt.")
            case let (audio?, reference?):
                if reference.isEmpty {
                    result.notes.append("\(sample.id): skipped, references/\(sample.id).txt is empty.")
                } else {
                    runnable.append((sample, audio, reference))
                }
            }
        }
        if runnable.isEmpty { result.notes.append("No sample has both a recording and a reference, so no engine ran.") }

        let claudeModes = options.modes.filter(\.usesClaude)
        var claudeUnavailable: CleanError?

        if !runnable.isEmpty {
            for engineRun in options.engines {
                deps.log("\(engineRun.label): preparing \(engineRun.engine.displayName)…")
                let load: (seconds: TimeInterval, downloaded: Bool)
                do {
                    load = try await deps.prepare(engineRun.engine)
                } catch {
                    result.notes.append("\(engineRun.label): couldn't load the model, so it was skipped (\(describe(error))).")
                    continue
                }
                if load.downloaded {
                    result.notes.append("\(engineRun.label): the model was downloaded during this run, so its load time includes the download.")
                }
                var loadReported = false
                for item in runnable {
                    for run in 1...options.runs {
                        let runLabel = options.runs > 1 ? " (run \(run)/\(options.runs))" : ""
                        deps.log("\(engineRun.label): \(item.sample.id)\(runLabel)…")
                        let transcription: SpikeTranscriptionResult
                        do {
                            transcription = try await deps.transcribe(item.audio, engineRun)
                        } catch {
                            result.notes.append("\(item.sample.id) · \(engineRun.label)\(runLabel): transcription failed (\(describe(error))).")
                            continue
                        }
                        var timings = BenchTimings(modelLoad: loadReported ? nil : load.seconds,
                                                   transcribe: transcription.timings.transcribe,
                                                   tailLatency: transcription.timings.tailLatency)
                        loadReported = true
                        if options.modes.contains(.raw) {
                            result.append(score(sample: item.sample, reference: item.reference, text: transcription.text,
                                                engine: engineRun.label, mode: "raw", model: "", timings: timings,
                                                corpus: corpus, glossaryTerms: glossaryTerms,
                                                warnings: transcription.warnings))
                        }
                        // The model load belongs to the first row only, whatever its mode.
                        timings.modelLoad = nil
                        for mode in claudeModes {
                            let config = options.modeConfigs[mode] ?? ModeConfig.defaults[mode]
                                ?? ModeConfig(id: mode, claudeModel: "haiku", timeout: 30)
                            if let claudeUnavailable {
                                result.notes.append("\(item.sample.id) · \(engineRun.label) · \(mode.rawValue): not run (\(CleanErrorText.shortName(claudeUnavailable))).")
                                continue
                            }
                            deps.log("\(engineRun.label): \(item.sample.id) · \(mode.rawValue) with \(config.claudeModel)\(runLabel)…")
                            var claudeTimings = timings
                            let started = SpikeClock.now()
                            do {
                                let cleaned = try await deps.clean(transcription.text, config)
                                claudeTimings.claudeTotal = cleaned.elapsed
                                result.append(score(sample: item.sample, reference: item.reference, text: cleaned.text,
                                                    engine: engineRun.label, mode: mode.rawValue,
                                                    model: config.claudeModel, timings: claudeTimings, corpus: corpus,
                                                    glossaryTerms: glossaryTerms, warnings: cleaned.warnings))
                            } catch {
                                let cleanError = error as? CleanError
                                claudeTimings.claudeTotal = SpikeClock.now() - started
                                let why = cleanError.map(CleanErrorText.describe) ?? describe(error)
                                result.notes.append("\(item.sample.id) · \(engineRun.label) · \(mode.rawValue): clean-up failed, the app would paste the raw text. \(why)")
                                let row = BenchRow(sample: item.sample.id, engine: engineRun.label, mode: mode.rawValue,
                                                   model: config.claudeModel, timings: claudeTimings)
                                result.rows.append(row)
                                result.details.append(SpikeBenchDetail(row: row, text: "", warnings: ["Failed: \(why)"]))
                                // No point asking again when there is no claude or no token.
                                switch cleanError {
                                case .claudeNotFound?, .notConnected?, .authFailed?: claudeUnavailable = cleanError
                                default: break
                                }
                            }
                        }
                    }
                }
                await deps.unload(engineRun.engine)
            }
        }

        // superwhisper's saved output, scored like everything else.
        for sample in samples {
            guard let text = try? corpus.superwhisperText(for: sample), !text.isEmpty else { continue }
            guard let reference = try? corpus.reference(for: sample), !reference.isEmpty else {
                result.notes.append("\(sample.id): superwhisper text found but no reference, so it wasn't scored.")
                continue
            }
            result.append(score(sample: sample, reference: reference, text: text, engine: "superwhisper",
                                mode: "saved", model: "", timings: BenchTimings(), corpus: corpus,
                                glossaryTerms: glossaryTerms, warnings: []))
        }
        return result
    }

    /// Scores one text and keeps the details for the report.
    static func score(sample: BenchSample, reference: String, text: String, engine: String, mode: String,
                      model: String, timings: BenchTimings, corpus: BenchCorpus, glossaryTerms: [String],
                      warnings: [String]) -> SpikeBenchDetail {
        let points = corpus.points(for: sample)
        let score = BenchScorer.score(reference: reference, hypothesis: text, glossaryTerms: glossaryTerms,
                                      points: points)
        let row = BenchRow(sample: sample.id, engine: engine, mode: mode, model: model, score: score, timings: timings)
        return SpikeBenchDetail(
            row: row, text: text,
            werErrors: score.wer.errorSummary(limit: 12),
            missedTerms: score.terms.missed.map { "\($0.term) (\($0.found)/\($0.referenceCount))" },
            missingPoints: score.points?.missing.map { "\($0.point.number). \($0.point.label): needs \($0.missingGroups.joined(separator: "; "))" } ?? [],
            retractedFound: score.points?.withRetracted.flatMap { coverage in coverage.retractedFound.map { "\(coverage.point.number). “\($0)”" } } ?? [],
            warnings: warnings)
    }

    static func describe(_ error: Error) -> String {
        if let cleanError = error as? CleanError { return CleanErrorText.describe(cleanError) }
        if let spikeError = error as? SpikeError { return spikeError.description }
        if let localized = error as? LocalizedError, let text = localized.errorDescription { return text }
        return String(describing: error)
    }
}

extension SpikeBenchResult {
    mutating func append(_ detail: SpikeBenchDetail) {
        rows.append(detail.row)
        details.append(detail)
    }
}

/// Writes `bench/results/<yyyy-mm-dd-hhmm>.md` and `.csv`.
public enum SpikeBenchReportWriter {
    /// "2026-11-10-1432", in the given time zone.
    public static func fileStem(date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }

    /// The Markdown file: BenchReport's table and summary, then the notes and the text behind every row.
    public static func markdown(result: SpikeBenchResult, title: String, settings: [String]) -> String {
        let note = settings.map { "- \($0)" }.joined(separator: "\n")
        var out = BenchReport(title: title, note: note, rows: result.rows).markdown()
        if !result.notes.isEmpty {
            out += "\n## Notes\n\n" + result.notes.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if !result.details.isEmpty {
            out += "\n## Details\n\nWER errors are on normalised words: `~ ref → hyp` substituted, `- word` missing, `+ word` added.\n"
            for detail in result.details {
                let row = detail.row
                let model = row.model.isEmpty ? "" : " · \(row.model)"
                out += "\n### \(row.sample) · \(row.engine) · \(row.mode)\(model)\n\n"
                var facts: [String] = []
                if let wer = row.wer { facts.append(String(format: "WER %.1f%%", wer * 100)) }
                if let hits = row.termHits, let total = row.termTotal { facts.append("terms \(hits)/\(total)") }
                if let covered = row.pointsCovered, let total = row.pointsTotal { facts.append("points \(covered)/\(total)") }
                if !facts.isEmpty { out += facts.joined(separator: " · ") + "\n\n" }
                if !detail.missedTerms.isEmpty { out += "- Terms missed: " + detail.missedTerms.joined(separator: ", ") + "\n" }
                if !detail.missingPoints.isEmpty {
                    out += "- Points missing:\n" + detail.missingPoints.map { "  - \($0)" }.joined(separator: "\n") + "\n"
                }
                if !detail.retractedFound.isEmpty {
                    out += "- Corrected-away phrases still there: " + detail.retractedFound.joined(separator: ", ") + "\n"
                }
                for warning in detail.warnings { out += "- \(warning)\n" }
                if !detail.werErrors.isEmpty {
                    out += "\n<details><summary>WER errors</summary>\n\n```\n\(detail.werErrors)\n```\n\n</details>\n"
                }
                if !detail.text.isEmpty {
                    out += "\n<details><summary>Text</summary>\n\n```text\n\(detail.text)\n```\n\n</details>\n"
                }
            }
        }
        return out
    }

    /// Writes both files into `directory` (created if needed) and returns their URLs. An existing stem gets "-2", "-3"….
    @discardableResult
    public static func write(result: SpikeBenchResult, title: String, settings: [String], to directory: URL,
                             date: Date = Date(), fileManager: FileManager = .default) throws -> (markdown: URL, csv: URL) {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = fileStem(date: date)
        var name = stem
        var counter = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent("\(name).md").path)
                || fileManager.fileExists(atPath: directory.appendingPathComponent("\(name).csv").path) {
            name = "\(stem)-\(counter)"
            counter += 1
        }
        let md = directory.appendingPathComponent("\(name).md")
        let csv = directory.appendingPathComponent("\(name).csv")
        try Data(markdown(result: result, title: title, settings: settings).utf8).write(to: md, options: .atomic)
        try Data(BenchReport(title: title, rows: result.rows).csv().utf8).write(to: csv, options: .atomic)
        return (md, csv)
    }
}
