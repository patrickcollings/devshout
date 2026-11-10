// Parakeet TDT 0.6B v3 through FluidAudio (Core ML, Neural Engine).
//
// Written against FluidAudio 0.18.3 (Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift, AsrManager.swift)
// without a Mac to compile on. Unsure of / to check on macOS:
// - `AsrModels.download(to:version:progressHandler:)` and `load(from:version:progressHandler:)` take the *repo folder*
//   (`…/parakeet-tdt-0.6b-v3/parakeet-tdt-0.6b-v3-coreml`) and write into its parent + FluidAudio's folder name, so the
//   last path component must stay `parakeet-tdt-0.6b-v3-coreml` (ModelLocations.parakeetRepoDirectory does this).
// - FluidAudio reports download progress as 0…0.5 of its fraction (then compile 0.5…1, once per component); we rescale
//   the download part and show compile/load as indeterminate. It gives no byte counts.
// - Passing a local `TdtDecoderState` inout to the `AsrManager` actor's async `transcribe` (as FluidAudio's docs do).
// - `tokenTimings` are relative to the samples we pass (the chunk), with word starts carrying a leading space.

import DevshoutCore
import FluidAudio
import Foundation

public actor ParakeetEngine: TranscriptionEngine {
    public nonisolated let id: EngineID = .parakeetV3
    public nonisolated let maxChunkDuration: TimeInterval = EngineID.parakeetV3.defaultMaxChunkDuration
    public nonisolated let acceptsVocabularyPrompt = false

    private let locations: ModelLocations
    private let queue = AsyncSerialQueue()
    private var manager: AsrManager?

    /// FluidAudio's ASR guard: it rejects audio shorter than 0.3 s.
    private static let minimumSamples = Int(Double(AudioFormat.sampleRate) * 0.3) + 160

    public init(locations: ModelLocations = .default) {
        self.locations = locations
    }

    /// Whether the model files are already in devshout's models folder (no download needed).
    public nonisolated static func isDownloaded(locations: ModelLocations = .default) -> Bool {
        AsrModels.modelsExist(at: locations.parakeetRepoDirectory, version: .v3)
    }

    public var isLoaded: Bool { manager != nil }

    // MARK: TranscriptionEngine

    public func prepare(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        try await queue.run { try await self.prepareNow(progress: progress) }
    }

    public func transcribe(_ chunk: AudioChunk, context: TranscriptionContext) async throws -> ChunkTranscript {
        try await queue.run { try await self.transcribeNow(chunk) }
    }

    public func unload() async {
        await queue.runUncancellable { await self.unloadNow() }
    }

    // MARK: Work (only ever called from `queue`, one at a time)

    private func prepareNow(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        let relay = ModelProgressRelay(progress)
        if manager != nil {
            relay.send(ModelProgress(phase: .ready, fraction: 1))
            return
        }

        try locations.ensureDirectory(for: .parakeetV3)
        let repoDirectory = locations.parakeetRepoDirectory

        if !AsrModels.modelsExist(at: repoDirectory, version: .v3) {
            relay.send(ModelProgress(phase: .downloading, fraction: 0, bytesTotal: EngineID.parakeetV3.approximateDownloadBytes))
            try await AsrModels.download(
                to: repoDirectory,
                version: .v3,
                progressHandler: { update in relay.send(Self.map(update, loading: false)) }
            )
        }

        relay.send(ModelProgress(phase: .loading))
        let models = try await AsrModels.load(
            from: repoDirectory,
            version: .v3,
            progressHandler: { update in relay.send(Self.map(update, loading: true)) }
        )
        let asrManager = AsrManager(config: .default)
        try await asrManager.loadModels(models)
        manager = asrManager

        // Warm up so the first real chunk doesn't pay for Core ML's first prediction.
        _ = try? await run(asrManager, samples: [Float](repeating: 0, count: AudioFormat.sampleRate))

        relay.send(ModelProgress(phase: .ready, fraction: 1))
    }

    private func transcribeNow(_ chunk: AudioChunk) async throws -> ChunkTranscript {
        if manager == nil {
            try await prepareNow(progress: { _ in })
        }
        guard let asrManager = manager else { throw ASRError.notInitialized }

        let started = Date()
        let samples = EngineAudio.padded(chunk.samples, toAtLeast: Self.minimumSamples)
        let result = try await run(asrManager, samples: samples)
        let offset = EngineTimings.offsetSeconds(of: chunk)
        let words: [TimedWord]? = result.tokenTimings.map { timings in
            EngineTimings.mergeSubwordTokens(
                timings.map { RawTiming(text: $0.token, start: $0.startTime, end: $0.endTime) },
                offset: offset
            )
        }

        return ChunkTranscript(
            index: chunk.index,
            startSample: chunk.startSample,
            endSample: chunk.endSample,
            overlapBefore: chunk.overlapBefore,
            text: TranscriptText.normalise(result.text),
            words: words,
            engine: id,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    private func unloadNow() async {
        guard let asrManager = manager else { return }
        manager = nil
        await asrManager.cleanup()
    }

    /// One stateless decode: every chunk starts from a fresh decoder state, because chunks are independent
    /// (overlaps are removed later by the stitcher).
    private func run(_ asrManager: AsrManager, samples: [Float]) async throws -> ASRResult {
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        return try await asrManager.transcribe(samples, decoderState: &decoderState)
    }

    // MARK: Progress

    /// FluidAudio's progress → ours. Its download phase fills 0…0.5 of `fractionCompleted`; compiling restarts for
    /// every component, so it is shown without a fraction.
    nonisolated static func map(_ update: DownloadProgress, loading: Bool) -> ModelProgress {
        switch update.phase {
        case .listing:
            return ModelProgress(phase: loading ? .loading : .downloading, fraction: loading ? nil : 0)
        case .downloading(_, let totalFiles):
            if loading || totalFiles == 0 {
                // Already on disk: FluidAudio's cached fast path.
                return ModelProgress(phase: loading ? .loading : .compiling)
            }
            return ModelProgress(phase: .downloading, fraction: min(1, max(0, update.fractionCompleted / 0.5)),
                                 bytesTotal: EngineID.parakeetV3.approximateDownloadBytes)
        case .compiling:
            return ModelProgress(phase: loading ? .loading : .compiling)
        }
    }
}
