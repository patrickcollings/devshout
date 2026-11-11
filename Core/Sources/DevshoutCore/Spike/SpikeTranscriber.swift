import Foundation

/// How `devshout-cli transcribe` runs a file.
public enum SpikeTranscriptionMode: String, Codable, Sendable, CaseIterable, Hashable {
    /// VAD → `ChunkPlanner` over the whole file → each chunk in order → `Stitcher` (what the app does after stop).
    case whole
    /// The same chunks and order, timed as if transcribed while recording: reports the tail latency.
    case live
    /// No VAD or chunking: the whole file in one engine call (the engine's own long-audio handling).
    case single
}

public struct SpikeTranscriptionOptions: Sendable {
    public var mode: SpikeTranscriptionMode
    /// When set: Whisper's vocabulary prompt and the `TextFixer` come from it.
    public var glossary: Glossary?
    /// Give Whisper the glossary's vocabulary prompt (turn off to measure whether it helps).
    public var useVocabularyPrompt: Bool
    public var plannerConfig: ChunkPlannerConfig
    public var language: String
    /// Live mode only: really wait until each chunk would exist before transcribing it, so the tail latency is
    /// measured on the clock rather than simulated. Takes as long as the recording.
    public var realTime: Bool
    /// Audio is passed to the VAD in slices of this many seconds.
    public var vadSliceSeconds: TimeInterval

    public init(mode: SpikeTranscriptionMode = .whole, glossary: Glossary? = nil, useVocabularyPrompt: Bool = true,
                plannerConfig: ChunkPlannerConfig = .default, language: String = "en", realTime: Bool = false,
                vadSliceSeconds: TimeInterval = 10) {
        self.mode = mode
        self.glossary = glossary
        self.useVocabularyPrompt = useVocabularyPrompt
        self.plannerConfig = plannerConfig
        self.language = language
        self.realTime = realTime
        self.vadSliceSeconds = vadSliceSeconds
    }
}

/// One chunk as transcribed.
public struct SpikeChunkReport: Codable, Sendable, Hashable {
    public var index: Int
    /// Seconds from the start of the recording.
    public var start: TimeInterval
    public var end: TimeInterval
    /// Seconds shared with the previous chunk (forced cuts).
    public var overlapBefore: TimeInterval
    /// When the chunk would exist during a live recording.
    public var availableAt: TimeInterval
    /// Live mode: when it would be transcribed (simulated, or measured with `realTime`).
    public var startedAt: TimeInterval?
    public var finishedAt: TimeInterval?
    /// How long the engine took.
    public var elapsed: TimeInterval
    public var text: String
    /// The engine's word timings (seconds from the start of the recording), when it gives any: what the
    /// stitcher works from at a forced seam.
    public var words: [TimedWord]?

    public init(index: Int, start: TimeInterval, end: TimeInterval, overlapBefore: TimeInterval,
                availableAt: TimeInterval, startedAt: TimeInterval? = nil, finishedAt: TimeInterval? = nil,
                elapsed: TimeInterval, text: String, words: [TimedWord]? = nil) {
        self.index = index
        self.start = start
        self.end = end
        self.overlapBefore = overlapBefore
        self.availableAt = availableAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.elapsed = elapsed
        self.text = text
        self.words = words
    }

    public var duration: TimeInterval { end - start }
}

public struct SpikeTranscriptionTimings: Codable, Sendable, Hashable {
    /// Download (first run only), compile and load the speech model. Set by whoever prepared the engine.
    public var modelLoad: TimeInterval?
    /// Whether `modelLoad` included a download.
    public var modelDownloaded: Bool?
    /// Loading the VAD model (set by the caller), and running it over the file.
    public var vadLoad: TimeInterval?
    public var vad: TimeInterval?
    /// Planning the chunks.
    public var planning: TimeInterval?
    /// The engine's time over all chunks (the sum of each call).
    public var transcribe: TimeInterval
    /// Stitching and glossary fixes.
    public var finalise: TimeInterval
    /// `transcribe` / audio duration: below 1 is faster than real time.
    public var realTimeFactor: Double?
    /// Live mode: from the end of the recording to the final text.
    public var tailLatency: TimeInterval?
    /// Live mode: whether `tailLatency` was measured on the clock (`realTime`) or simulated.
    public var tailLatencyMeasured: Bool?

    public init(modelLoad: TimeInterval? = nil, modelDownloaded: Bool? = nil, vadLoad: TimeInterval? = nil,
                vad: TimeInterval? = nil, planning: TimeInterval? = nil, transcribe: TimeInterval = 0,
                finalise: TimeInterval = 0, realTimeFactor: Double? = nil, tailLatency: TimeInterval? = nil,
                tailLatencyMeasured: Bool? = nil) {
        self.modelLoad = modelLoad
        self.modelDownloaded = modelDownloaded
        self.vadLoad = vadLoad
        self.vad = vad
        self.planning = planning
        self.transcribe = transcribe
        self.finalise = finalise
        self.realTimeFactor = realTimeFactor
        self.tailLatency = tailLatency
        self.tailLatencyMeasured = tailLatencyMeasured
    }
}

/// What `devshout-cli transcribe --json` prints.
public struct SpikeTranscriptionResult: Codable, Sendable, Hashable {
    public var engine: EngineID
    public var mode: SpikeTranscriptionMode
    public var audioFile: String?
    /// Seconds of audio (16 kHz).
    public var audioDuration: TimeInterval
    /// The final text: `rawText` with the glossary's fixes applied (the same when there is no glossary).
    public var text: String
    /// The stitched transcript, before glossary fixes.
    public var rawText: String
    /// Each glossary fix, as "core sea → CORSIA".
    public var glossaryFixes: [String]
    /// The Whisper vocabulary prompt used (nil for Parakeet, or with no glossary or the prompt turned off).
    public var vocabularyPrompt: String?
    public var vocabularyTokens: Int?
    /// Which token counter measured `vocabularyTokens` ("WhisperKit tokenizer" or "approximate").
    public var tokenCounter: String?
    public var chunks: [SpikeChunkReport]
    public var timings: SpikeTranscriptionTimings
    public var warnings: [String]

    public init(engine: EngineID, mode: SpikeTranscriptionMode, audioFile: String? = nil, audioDuration: TimeInterval,
                text: String, rawText: String, glossaryFixes: [String] = [], vocabularyPrompt: String? = nil,
                vocabularyTokens: Int? = nil, tokenCounter: String? = nil, chunks: [SpikeChunkReport],
                timings: SpikeTranscriptionTimings, warnings: [String] = []) {
        self.engine = engine
        self.mode = mode
        self.audioFile = audioFile
        self.audioDuration = audioDuration
        self.text = text
        self.rawText = rawText
        self.glossaryFixes = glossaryFixes
        self.vocabularyPrompt = vocabularyPrompt
        self.vocabularyTokens = vocabularyTokens
        self.tokenCounter = tokenCounter
        self.chunks = chunks
        self.timings = timings
        self.warnings = warnings
    }

    /// Pretty-printed JSON with sorted keys.
    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// The human-readable timing lines for stderr.
    public var timingLines: [String] {
        var lines: [String] = []
        lines.append("Audio: \(SpikeFormat.clock(audioDuration)) (\(SpikeFormat.seconds(audioDuration))), "
                     + "\(chunks.count) \(chunks.count == 1 ? "chunk" : "chunks"), engine \(engine.displayName), mode \(mode.rawValue)")
        if let load = timings.modelLoad {
            lines.append("Model load: \(SpikeFormat.seconds(load))\(timings.modelDownloaded == true ? " (including the download)" : "")")
        }
        if let vadLoad = timings.vadLoad { lines.append("VAD load: \(SpikeFormat.seconds(vadLoad))") }
        if let vad = timings.vad { lines.append("VAD over the file: \(SpikeFormat.seconds(vad))") }
        lines.append("Transcription: \(SpikeFormat.seconds(timings.transcribe)) · "
                     + SpikeFormat.realTimeFactorDescription(timings.realTimeFactor))
        if let tail = timings.tailLatency {
            lines.append("Tail latency (end of recording → final text): \(SpikeFormat.seconds(tail))"
                         + (timings.tailLatencyMeasured == true ? " (measured in real time)" : " (simulated)"))
        }
        if let prompt = vocabularyPrompt {
            let tokens = vocabularyTokens.map { "\($0) tokens" } ?? "? tokens"
            lines.append("Whisper prompt: \(tokens) by \(tokenCounter ?? "?"): \(prompt)")
        }
        if !glossaryFixes.isEmpty { lines.append("Glossary fixes: " + glossaryFixes.joined(separator: "; ")) }
        lines += warnings.map { "Warning: \($0)" }
        return lines
    }
}

/// Runs one recording through VAD, `ChunkPlanner`, an engine, `Stitcher` and `TextFixer` the way the app does, and
/// times each step. Everything is behind Core protocols, so it is tested on Linux with fakes; `devshout-cli` plugs in
/// FluidAudio, WhisperKit and Silero.
public struct SpikeTranscriber: Sendable {
    public var engine: any TranscriptionEngine
    /// Needed for `whole` and `live`.
    public var vad: (any VoiceActivityDetector)?
    /// The probability of a final partial frame, if the detector can give one (`SileroVAD.processRemainder`).
    public var vadRemainder: (@Sendable () async throws -> Float?)?
    /// For Whisper's prompt budget: WhisperKit's tokenizer on the Mac, else `ApproximateTokenCounter`.
    public var tokenCounter: any TokenCounter
    public var tokenCounterName: String

    public init(engine: any TranscriptionEngine, vad: (any VoiceActivityDetector)?,
                vadRemainder: (@Sendable () async throws -> Float?)? = nil,
                tokenCounter: any TokenCounter = ApproximateTokenCounter(), tokenCounterName: String = "approximate") {
        self.engine = engine
        self.vad = vad
        self.vadRemainder = vadRemainder
        self.tokenCounter = tokenCounter
        self.tokenCounterName = tokenCounterName
    }

    /// Prepares the engine and returns how long it took.
    public func prepareEngine(progress: @escaping @Sendable (ModelProgress) -> Void) async throws -> TimeInterval {
        let start = SpikeClock.now()
        try await engine.prepare(progress: progress)
        return SpikeClock.now() - start
    }

    /// Speech probabilities for the whole recording, one per frame (plus one for a final partial frame when the
    /// detector gives it).
    public func speechProbabilities(_ samples: [Float], sliceSeconds: TimeInterval = 10) async throws -> [Float] {
        guard let vad else { throw SpikeError.missingVAD }
        await vad.reset()
        let slice = max(vad.frameSize, Int(sliceSeconds * Double(AudioFormat.sampleRate)))
        var probabilities: [Float] = []
        var position = 0
        while position < samples.count {
            let end = min(position + slice, samples.count)
            probabilities += try await vad.process(Array(samples[position..<end]))
            position = end
        }
        if let vadRemainder, let last = try await vadRemainder() { probabilities.append(last) }
        return probabilities
    }

    /// The chunks to transcribe and when each would exist during a live recording.
    public func plan(_ samples: [Float], options: SpikeTranscriptionOptions,
                     timings: inout SpikeTranscriptionTimings) async throws -> [ScheduledChunk] {
        let duration = Double(samples.count) / Double(AudioFormat.sampleRate)
        if options.mode == .single {
            guard !samples.isEmpty else { return [] }
            let chunk = AudioChunk(index: 0, startSample: 0, endSample: samples.count, samples: samples)
            return [ScheduledChunk(chunk: chunk, availableAt: duration)]
        }
        guard let vad else { throw SpikeError.missingVAD }
        let vadStart = SpikeClock.now()
        let probabilities = try await speechProbabilities(samples, sliceSeconds: options.vadSliceSeconds)
        timings.vad = SpikeClock.now() - vadStart
        let planStart = SpikeClock.now()
        let schedule = LiveChunkSchedule.schedule(samples: samples, probabilities: probabilities,
                                                  frameSize: vad.frameSize, config: options.plannerConfig,
                                                  maxChunkDuration: engine.maxChunkDuration)
        timings.planning = SpikeClock.now() - planStart
        return schedule
    }

    /// Transcribes 16 kHz mono samples. Does not prepare the engine (call `prepareEngine` first to time it apart).
    public func run(samples: [Float], options: SpikeTranscriptionOptions,
                    audioFile: String? = nil) async throws -> SpikeTranscriptionResult {
        let rate = Double(AudioFormat.sampleRate)
        let duration = Double(samples.count) / rate
        var timings = SpikeTranscriptionTimings()
        var warnings: [String] = []

        let schedule = try await plan(samples, options: options, timings: &timings)
        if schedule.isEmpty { warnings.append("No speech was detected.") }

        // Whisper's vocabulary prompt, built once per recording as the app does.
        let builder = WhisperPromptBuilder(tokenCounter: tokenCounter)
        var vocabulary: WhisperVocabulary?
        if engine.acceptsVocabularyPrompt, options.useVocabularyPrompt, let glossary = options.glossary {
            let built = builder.vocabulary(for: glossary)
            vocabulary = built
            if built.includedCount < built.candidateCount {
                warnings.append("The Whisper prompt holds \(built.includedCount) of \(built.candidateCount) glossary terms (token budget).")
            }
        }
        let prompt = vocabulary.flatMap { $0.prompt.isEmpty ? nil : $0.prompt }

        let realTime = options.mode == .live && options.realTime
        let clockStart = SpikeClock.now()
        var transcripts: [ChunkTranscript] = []
        var elapsed: [TimeInterval] = []
        var measuredStarts: [TimeInterval] = []
        var measuredFinishes: [TimeInterval] = []
        for item in schedule {
            if realTime {
                let wait = clockStart + item.availableAt - SpikeClock.now()
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
            let context: TranscriptionContext
            if engine.acceptsVocabularyPrompt {
                context = TranscriptionContext(language: options.language, vocabularyPrompt: prompt,
                                               previousText: builder.previousTextTail(transcripts.last?.text))
            } else {
                context = TranscriptionContext(language: options.language)
            }
            let start = SpikeClock.now()
            let transcript = try await engine.transcribe(item.chunk, context: context)
            let finish = SpikeClock.now()
            transcripts.append(transcript)
            elapsed.append(finish - start)
            measuredStarts.append(start - clockStart)
            measuredFinishes.append(finish - clockStart)
        }
        timings.transcribe = elapsed.reduce(0, +)
        timings.realTimeFactor = SpikeFormat.realTimeFactor(processing: timings.transcribe, audio: duration)

        let finaliseStart = SpikeClock.now()
        let raw = Stitcher.stitch(transcripts)
        var text = raw
        var fixes: [String] = []
        if let glossary = options.glossary {
            let fixed = TextFixer.fix(raw, glossary: glossary)
            text = fixed.text
            fixes = fixed.replacements.map { "\($0.original) → \($0.replacement)" }
        }
        let finaliseEnd = SpikeClock.now()
        timings.finalise = finaliseEnd - finaliseStart

        var starts: [TimeInterval?] = Array(repeating: nil, count: schedule.count)
        var finishes: [TimeInterval?] = Array(repeating: nil, count: schedule.count)
        if options.mode == .live {
            if realTime {
                starts = measuredStarts
                finishes = measuredFinishes
                timings.tailLatency = max(0, (finaliseEnd - clockStart) - duration)
                timings.tailLatencyMeasured = true
            } else {
                let timeline = LiveTimeline.simulate(availableAt: schedule.map(\.availableAt), durations: elapsed,
                                                     recordingDuration: duration, finalisation: timings.finalise)
                starts = timeline.starts
                finishes = timeline.finishes
                timings.tailLatency = timeline.tailLatency
                timings.tailLatencyMeasured = false
            }
        }

        let chunks = schedule.enumerated().map { index, item -> SpikeChunkReport in
            SpikeChunkReport(index: item.chunk.index,
                             start: Double(item.chunk.startSample) / rate,
                             end: Double(item.chunk.endSample) / rate,
                             overlapBefore: Double(item.chunk.overlapBefore) / rate,
                             availableAt: item.availableAt,
                             startedAt: starts[index], finishedAt: finishes[index],
                             elapsed: index < elapsed.count ? elapsed[index] : 0,
                             text: index < transcripts.count ? transcripts[index].text : "",
                             words: index < transcripts.count ? transcripts[index].words : nil)
        }
        if !schedule.isEmpty, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append("The engine returned no text.")
        }

        return SpikeTranscriptionResult(engine: engine.id, mode: options.mode, audioFile: audioFile,
                                        audioDuration: duration, text: text, rawText: raw, glossaryFixes: fixes,
                                        vocabularyPrompt: prompt, vocabularyTokens: prompt == nil ? nil : vocabulary?.tokenCount,
                                        tokenCounter: prompt == nil ? nil : tokenCounterName, chunks: chunks,
                                        timings: timings, warnings: warnings)
    }
}
