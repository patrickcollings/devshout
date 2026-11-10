// VoiceActivityDetector backed by FluidAudio's Silero VAD (Core ML, 4,096-sample / 256 ms frames at 16 kHz).
//
// Built against FluidAudio 0.18.3: `VadManager(config:modelDirectory:progressHandler:)` loads (and on first run
// downloads) the model under `<modelDirectory>/Models/silero-vad-coreml/`, so passing devshout's Application Support
// folder puts it in `~/Library/Application Support/devshout/Models/silero-vad-coreml/` (PLAN §3.5).
// Streaming uses the public `processStreamingChunk(_:state:)`, which carries the LSTM state between frames.
//
// Unsure on macOS (not compiled in CI yet):
// - First-run download size/time, and whether ANE compilation makes the first `prepare()` slow (seconds).
// - Calling `process` concurrently from two tasks: actor re-entrancy could interleave frames. Callers (the pipeline)
//   should await each call before the next, which is what the protocol implies.
import DevshoutCore
import FluidAudio
import Foundation

public actor SileroVAD: VoiceActivityDetector {
    /// Samples per frame: what FluidAudio's Silero model takes per step (4,096 = 256 ms at 16 kHz).
    public nonisolated var frameSize: Int { VadManager.chunkSize }

    /// `~/Library/Application Support/devshout`. FluidAudio adds `Models/silero-vad-coreml` below it.
    public static var defaultBaseDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("devshout", isDirectory: true)
    }

    public nonisolated let baseDirectory: URL
    private let config: VadConfig
    private var manager: VadManager?
    private var preparing: Task<VadManager, Error>?
    private var streamState = VadStreamState.initial()
    private var accumulator = FrameAccumulator(frameSize: VadManager.chunkSize)

    /// - Parameter baseDirectory: Folder that gets a `Models/` subfolder for the Core ML bundle.
    public init(baseDirectory: URL = SileroVAD.defaultBaseDirectory, config: VadConfig = .default) {
        self.baseDirectory = baseDirectory
        self.config = config
    }

    /// Where the model bundle lives once downloaded.
    public nonisolated var modelDirectory: URL {
        baseDirectory.appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(Repo.vad.folderName, isDirectory: true)
    }

    public func prepare() async throws {
        try await prepare(progress: nil)
    }

    /// As `prepare()`, reporting download and compile progress.
    public func prepare(progress: (@Sendable (ModelProgress) -> Void)?) async throws {
        _ = try await loadedManager(progress: progress)
    }

    public var isReady: Bool { manager != nil }

    /// Speech probability for each complete 4,096-sample frame. Loads the model first if `prepare()` wasn't called.
    public func process(_ samples: [Float]) async throws -> [Float] {
        let frames = accumulator.append(samples)
        guard !frames.isEmpty else { return [] }
        let manager = try await loadedManager(progress: nil)
        var probabilities: [Float] = []
        probabilities.reserveCapacity(frames.count)
        for frame in frames {
            let result = try await manager.processStreamingChunk(frame, state: streamState)
            streamState = result.state
            probabilities.append(result.probability)
        }
        return probabilities
    }

    /// The probability for the leftover samples (fewer than a frame), padded the way FluidAudio pads a short chunk.
    /// Call once at the end of a recording; returns nil when nothing was left over.
    public func processRemainder() async throws -> Float? {
        let rest = accumulator.drain()
        guard !rest.isEmpty else { return nil }
        let manager = try await loadedManager(progress: nil)
        let result = try await manager.processStreamingChunk(rest, state: streamState)
        streamState = result.state
        return result.probability
    }

    /// Forgets the model's state and any buffered samples, ready for a new recording. The model stays loaded.
    public func reset() async {
        streamState = VadStreamState.initial()
        accumulator.reset()
    }

    /// Drops the model from memory; the next call loads it again.
    public func unload() async {
        manager = nil
        preparing = nil
        await reset()
    }

    private func loadedManager(progress: (@Sendable (ModelProgress) -> Void)?) async throws -> VadManager {
        if let manager { return manager }
        if let preparing { return try await preparing.value }
        let directory = baseDirectory
        let config = config
        var handler: ProgressHandler?
        if let progress {
            handler = { download in progress(SileroVAD.modelProgress(from: download)) }
        }
        let task = Task { try await VadManager(config: config, modelDirectory: directory, progressHandler: handler) }
        preparing = task
        do {
            let loaded = try await task.value
            manager = loaded
            preparing = nil
            progress?(ModelProgress(phase: .ready, fraction: 1))
            return loaded
        } catch {
            preparing = nil
            throw error
        }
    }

    nonisolated static func modelProgress(from download: DownloadProgress) -> ModelProgress {
        if case .compiling = download.phase {
            return ModelProgress(phase: .compiling, fraction: download.fractionCompleted)
        }
        return ModelProgress(phase: .downloading, fraction: download.fractionCompleted)
    }
}
