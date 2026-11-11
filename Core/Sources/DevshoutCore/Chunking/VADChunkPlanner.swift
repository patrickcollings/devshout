import Foundation

/// The app's `LiveChunkPlanner`: a voice activity detector feeding `ChunkPlanner`, for one recording.
///
/// The audio goes to the detector as it arrives, and the detector's speech probabilities go to the planner with it,
/// so a chunk is handed back as soon as the pause that ends it has been heard. The cuts are exactly those of running
/// the detector and `ChunkPlanner.plan` over the whole recording afterwards, however the audio was split into calls.
///
/// Without a detector (its model isn't downloaded yet, say), or once it has failed, every frame counts as speech:
/// the planner then makes fixed-length chunks with overlaps, and nothing is lost.
///
/// The detector is shared by the whole app and keeps state between calls, so only one recording may use it at a
/// time. It is reset when this planner sees its first audio.
public actor VADChunkPlanner: LiveChunkPlanner {
    /// A detector, and how to score the samples left over at the end of a recording (fewer than a frame), when it
    /// can (`SileroVAD.processRemainder`).
    public struct Detector: Sendable {
        public var vad: any VoiceActivityDetector
        public var remainder: (@Sendable () async throws -> Float?)?

        public init(vad: any VoiceActivityDetector, remainder: (@Sendable () async throws -> Float?)? = nil) {
            self.vad = vad
            self.remainder = remainder
        }
    }

    private let frameSize: Int
    private let defersUntilFinish: Bool
    private let makeDetector: @Sendable () async -> Detector?

    private var planner: ChunkPlanner
    private var detector: Detector?
    private var detectorResolved = false
    private var samplesReceived = 0
    /// Frames the planner has been given a probability for.
    private var framesScored = 0
    private var deferred: [Float] = []

    /// - Parameters:
    ///   - maxChunkDuration: the engine's limit in seconds (`TranscriptionEngine.maxChunkDuration`).
    ///   - frameSize: samples per detector frame (`VoiceActivityDetector.frameSize`).
    ///   - defersUntilFinish: hand back every chunk from `finish()`, none while recording: the recording is then
    ///     transcribed after stop, as devshout did before it transcribed live. For measuring the difference.
    ///   - detector: asked once, when the first audio arrives. Return nil to plan without a detector rather than
    ///     wait for one (loading it may mean a download).
    public init(maxChunkDuration: TimeInterval, frameSize: Int, config: ChunkPlannerConfig = .default,
                defersUntilFinish: Bool = false, detector: @escaping @Sendable () async -> Detector?) {
        self.frameSize = frameSize
        self.defersUntilFinish = defersUntilFinish
        self.makeDetector = detector
        planner = ChunkPlanner(config: config, maxChunkDuration: maxChunkDuration, frameSize: frameSize)
    }

    public func append(_ samples: [Float]) async -> [AudioChunk] {
        if defersUntilFinish {
            deferred.append(contentsOf: samples)
            return []
        }
        return await feed(samples)
    }

    public func finish() async -> [AudioChunk] {
        var chunks: [AudioChunk] = []
        if defersUntilFinish {
            chunks += await feed(deferred)
            deferred = []
        }
        if let remainder = detector?.remainder, let last = try? await remainder() {
            chunks += planner.append(samples: [], probabilities: [last])
        }
        // A final partial frame the detector didn't score takes the last probability (speech, with no detector).
        chunks += planner.finish()
        return chunks
    }

    private func feed(_ samples: [Float]) async -> [AudioChunk] {
        if !detectorResolved {
            detectorResolved = true
            detector = await makeDetector()
            await detector?.vad.reset()
        }
        samplesReceived += samples.count
        var probabilities: [Float] = []
        if let vad = detector?.vad {
            do {
                probabilities = try await vad.process(samples)
            } catch {
                // Carry on without it: what it didn't score counts as speech, so no words are dropped.
                detector = nil
            }
        }
        if detector == nil {
            probabilities = Array(repeating: 1, count: max(0, samplesReceived / frameSize - framesScored))
        }
        framesScored += probabilities.count
        return planner.append(samples: samples, probabilities: probabilities)
    }
}
