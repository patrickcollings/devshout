// Whisper large-v3-turbo through WhisperKit (argmax-oss-swift), with the glossary as a vocabulary prompt.
//
// Written against argmax-oss-swift 1.1.1 (Sources/WhisperKit/Core/WhisperKit.swift, Configurations.swift, Models.swift,
// TextDecoder.swift) without a Mac to compile on. Unsure of / to check on macOS:
// - WhisperKit also defines `AudioChunk`, so this file always writes `DevshoutCore.AudioChunk`.
// - `WhisperKit.download(variant:downloadBase:from:progressCallback:)` puts files under
//   `<downloadBase>/models/argmaxinc/whisperkit-coreml/<variant>/` and returns that folder. We mark it complete
//   ourselves; `ModelLocations.completedWhisperModelFolder()` also searches the base in case the layout differs.
// - Its progress counts files (each file 0…100), not bytes, so the fraction moves unevenly (one 600 MB weight file).
// - The tokenizer is not in the variant folder: it comes from the `openai/whisper-large-v3` Hub repo into
//   `tokenizerFolder` (our download base). We fetch it straight after the model so a later offline load works;
//   if that fails, WhisperKit retries on load.
// - `WhisperKit` and `WhisperTokenizer` are not `Sendable`; they are only touched from this actor (and the token
//   counter's lock). Swift 5 mode may still warn about sending the WhisperKit instance to its own async methods.
// - Word timings (`TranscriptionSegment.words`) are taken as relative to the start of the audio array we pass.
// - WhisperKit adds `<|startofprev|>` before `promptTokens` and keeps only their last 223, so we cap ours at 223.

import DevshoutCore
import Foundation
import WhisperKit

public enum WhisperEngineError: Error, LocalizedError, Sendable {
    case tokenizerUnavailable

    public var errorDescription: String? {
        switch self {
        case .tokenizerUnavailable: "Whisper loaded, but its tokenizer could not be loaded."
        }
    }
}

public actor WhisperEngine: TranscriptionEngine {
    public nonisolated let id: EngineID = .whisperLargeV3Turbo
    public nonisolated let maxChunkDuration: TimeInterval = EngineID.whisperLargeV3Turbo.defaultMaxChunkDuration
    public nonisolated let acceptsVocabularyPrompt = true
    /// Counts tokens with this engine's tokenizer once it is loaded (an approximation before that).
    public nonisolated let tokenCounter: WhisperTokenCounter

    private let locations: ModelLocations
    private let queue = AsyncSerialQueue()
    private var whisperKit: WhisperKit?

    /// Whisper's window is 30 s; anything longer (a whole-file fallback) goes through WhisperKit's own VAD chunking.
    private static let windowSamples = 30 * AudioFormat.sampleRate

    public init(locations: ModelLocations = .default, tokenCounter: WhisperTokenCounter = WhisperTokenCounter()) {
        self.locations = locations
        self.tokenCounter = tokenCounter
    }

    /// Whether the model files are already in devshout's models folder (no download needed).
    public nonisolated static func isDownloaded(locations: ModelLocations = .default) -> Bool {
        locations.completedWhisperModelFolder() != nil
    }

    public var isLoaded: Bool { whisperKit != nil }

    // MARK: TranscriptionEngine

    public func prepare(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        try await queue.run { try await self.prepareNow(progress: progress) }
    }

    public func transcribe(_ chunk: DevshoutCore.AudioChunk, context: TranscriptionContext) async throws -> ChunkTranscript {
        try await queue.run { try await self.transcribeNow(chunk, context: context) }
    }

    public func unload() async {
        await queue.runUncancellable { await self.unloadNow() }
    }

    // MARK: Work (only ever called from `queue`, one at a time)

    private func prepareNow(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        let relay = ModelProgressRelay(progress)
        if whisperKit != nil {
            relay.send(ModelProgress(phase: .ready, fraction: 1))
            return
        }

        try locations.ensureDirectory(for: .whisperLargeV3Turbo)
        let downloadBase = locations.whisperDownloadBase
        let variant = EngineID.whisperLargeV3Turbo.modelVariant
        let approximateBytes = EngineID.whisperLargeV3Turbo.approximateDownloadBytes

        let modelFolder: URL
        let freshDownload: Bool
        if let existing = locations.completedWhisperModelFolder() {
            modelFolder = existing
            freshDownload = false
        } else {
            relay.send(ModelProgress(phase: .downloading, fraction: 0, bytesTotal: approximateBytes))
            let downloaded = try await WhisperKit.download(
                variant: variant,
                downloadBase: downloadBase,
                from: EngineID.whisperLargeV3Turbo.modelRepository,
                progressCallback: { fileProgress in
                    relay.send(ModelProgress(phase: .downloading, fraction: fileProgress.fractionCompleted,
                                             bytesTotal: approximateBytes))
                }
            )
            // The tokenizer is a separate, small download; best effort here, WhisperKit retries on load.
            _ = try? await ModelUtilities.loadTokenizer(for: .largev3, tokenizerFolder: downloadBase)
            try ModelLocations.markComplete(downloaded)
            modelFolder = downloaded
            freshDownload = true
        }

        // First load after a download specialises the Core ML models for this Mac (slow, once).
        relay.send(ModelProgress(phase: freshDownload ? .compiling : .loading))
        let config = WhisperKitConfig(
            model: variant,
            downloadBase: downloadBase,
            modelRepo: EngineID.whisperLargeV3Turbo.modelRepository,
            modelFolder: modelFolder.path,
            tokenizerFolder: downloadBase,
            verbose: false,
            logLevel: .error,
            prewarm: freshDownload,
            load: true,
            download: false
        )
        let kit = try await WhisperKit(config)
        guard let tokenizer = kit.tokenizer else {
            await kit.unloadModels()
            throw WhisperEngineError.tokenizerUnavailable
        }
        whisperKit = kit
        tokenCounter.setTokenizer(tokenizer)

        // Warm up so the first real chunk doesn't pay for Core ML's first prediction.
        relay.send(ModelProgress(phase: .loading))
        _ = try? await kit.transcribe(
            audioArray: [Float](repeating: 0, count: AudioFormat.sampleRate),
            decodeOptions: Self.decodingOptions(language: "en", promptTokens: nil, longAudio: false)
        )

        relay.send(ModelProgress(phase: .ready, fraction: 1))
    }

    private func transcribeNow(_ chunk: DevshoutCore.AudioChunk, context: TranscriptionContext) async throws -> ChunkTranscript {
        if whisperKit == nil {
            try await prepareNow(progress: { _ in })
        }
        guard let kit = whisperKit else { throw WhisperError.modelsUnavailable("Whisper is not loaded.") }

        let started = Date()
        let promptTokens = promptTokens(for: context)
        let options = Self.decodingOptions(
            language: context.language.isEmpty ? "en" : context.language,
            promptTokens: promptTokens.isEmpty ? nil : promptTokens,
            longAudio: chunk.samples.count > Self.windowSamples
        )
        let results = try await kit.transcribe(audioArray: chunk.samples, decodeOptions: options)

        let offset = EngineTimings.offsetSeconds(of: chunk)
        var text = TranscriptText.normalise(results.map(\.text).joined(separator: " "))
        let rawWords = results.flatMap { result in
            result.segments.flatMap { segment in
                (segment.words ?? []).map { RawTiming(text: $0.word, start: Double($0.start), end: Double($0.end)) }
            }
        }
        var words = EngineTimings.words(from: rawWords, offset: offset)

        // Whisper sometimes just repeats its prompt over near-silence: treat that as no speech.
        if TranscriptText.isPromptEcho(text, prompt: context.vocabularyPrompt) {
            text = ""
            words = []
        }

        return ChunkTranscript(
            index: chunk.index,
            startSample: chunk.startSample,
            endSample: chunk.endSample,
            overlapBefore: chunk.overlapBefore,
            text: text,
            words: words,
            engine: id,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    private func unloadNow() async {
        guard let kit = whisperKit else { return }
        whisperKit = nil
        tokenCounter.setTokenizer(nil)
        await kit.unloadModels()
    }

    // MARK: Prompt and options

    /// Vocabulary prompt, then the tail of the previous chunk, within Whisper's 224-token prompt limit.
    private func promptTokens(for context: TranscriptionContext) -> [Int] {
        let vocabulary = WhisperPromptTokens.promptText(context.vocabularyPrompt)
            .flatMap { tokenCounter.encode($0) } ?? []
        let previous = WhisperPromptTokens.promptText(context.previousText)
            .flatMap { tokenCounter.encode($0) } ?? []
        return WhisperPromptTokens.assemble(vocabulary: vocabulary, previous: previous)
    }

    static func decodingOptions(language: String, promptTokens: [Int]?, longAudio: Bool) -> DecodingOptions {
        var options = DecodingOptions()
        options.verbose = false
        options.task = .transcribe
        options.language = language
        options.detectLanguage = false
        options.usePrefillPrompt = true          // needed for the language token and promptTokens
        options.skipSpecialTokens = true
        options.withoutTimestamps = false
        options.wordTimestamps = true
        options.promptTokens = promptTokens
        // Temperature fallback: WhisperKit's defaults (0, then +0.2 up to 5 times) when a decode fails the checks below.
        options.temperature = 0
        options.temperatureIncrementOnFallback = 0.2
        options.temperatureFallbackCount = 5
        // OpenAI's thresholds: repetitive output, low confidence and no-speech windows are retried or dropped.
        options.compressionRatioThreshold = 2.4
        options.logProbThreshold = -1.0
        options.firstTokenLogProbThreshold = -1.5
        options.noSpeechThreshold = 0.6
        options.concurrentWorkerCount = 1
        options.chunkingStrategy = longAudio ? .vad : nil
        return options
    }
}
