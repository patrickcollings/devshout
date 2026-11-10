import Foundation

/// Cuts a recording into chunks for transcription while it is being recorded (PLAN §4.1).
///
/// Feed it audio and the VAD's speech probabilities as they arrive with `append(samples:probabilities:)`, and
/// call `finish()` when recording stops. Both return the chunks that became final. The cuts depend only on the
/// audio and the probabilities, never on how the input was split into calls, so `plan(...)` on a whole recording
/// gives exactly the chunks that streaming gives.
///
/// The rules:
/// - **Speech** is decided per VAD frame with hysteresis: a frame at or above `speechThreshold` starts speech, and
///   only a frame below `speechThreshold - speechExitOffset` ends it.
/// - **Natural cut:** once a chunk has `minSpeechBeforeCut` of speech, the first silence that reaches `cutSilence`
///   ends it. The cut goes in the middle of that silence (as long as it is when it qualifies), so the chunk can be
///   transcribed without waiting for the speaker to carry on. No overlap.
/// - **Forced cut:** a chunk never exceeds the engine's maximum. When it would, and the chunk contains a silence of
///   `cutSilence` that came too early for a natural cut, it is cut there (no overlap). Otherwise it is cut at the
///   lowest-probability frame (the latest, on a tie) in the last `forcedCutSearchWindow` before the limit. When that
///   frame is speech, the next chunk starts `forcedCutOverlap` earlier, so `overlapBefore` > 0; when it is silence,
///   nothing is split and there is no overlap.
/// - **Padding:** a chunk spans its speech plus `padding` either side, within its cut points. Silence beyond that
///   (pauses before the speaker starts, or after they stop) is never sent to the engine.
/// - **Skip:** a chunk with less than `minSpeechToTranscribe` of speech is dropped. `index` counts emitted chunks
///   only, so it stays consecutive.
///
/// Positions are in samples from the start of the recording (16 kHz). Memory stays bounded by the current chunk:
/// audio and frames before it are released as the recording goes on.
public struct ChunkPlanner: Sendable {
    public let config: ChunkPlannerConfig
    /// Samples per VAD frame (FluidAudio's Silero VAD: 4,096).
    public let frameSize: Int
    /// The longest chunk, in samples. At least two frames plus padding either side, whatever was asked for.
    public let maxChunkSamples: Int

    private let minSpeechBeforeCutSamples: Int
    private let cutSilenceSamples: Int
    private let windowSamples: Int
    private let overlapSamples: Int
    private let minSpeechSamples: Int
    private let paddingSamples: Int
    private let enterThreshold: Float
    private let exitThreshold: Float

    // Audio: buffer[0] is sample `bufferStart` of the recording.
    private var buffer: [Float] = []
    private var bufferStart = 0
    private var totalSamples: Int { bufferStart + buffer.count }

    // VAD frames received so far: frames[0] is frame `framesStart` of the recording.
    private var frames: [Frame] = []
    private var framesStart = 0
    private var framesReceived: Int { framesStart + frames.count }
    private var inSpeech = false
    private var lastProbability: Float?

    // The chunk being built, and the next frame to look at for it.
    private var segment = Segment(start: 0)
    private var nextFrame = 0

    private var nextIndex = 0
    private var lastEmittedEnd: Int?
    private var finished = false

    private struct Frame: Sendable {
        var probability: Float
        var isSpeech: Bool
    }

    /// The chunk in progress. It starts at a cut point; its audio starts at the first speech (minus padding).
    private struct Segment: Sendable {
        var start: Int
        /// Where the chunk's audio starts; nil until the first speech frame.
        var audioStart: Int?
        var speechSamples = 0
        var silenceRunStart: Int?
        var silenceRunQualified = false
        /// The middle of the latest silence of `cutSilence` that came before `minSpeechBeforeCut` of speech.
        var earlySilenceCut: Int?
    }

    private enum Step {
        case next
        /// End the chunk at `end` (before padding is trimmed) and start the next one at `nextStart`.
        case cut(end: Int, nextStart: Int)
    }

    /// - Parameters:
    ///   - maxChunkDuration: the engine's limit in seconds (`TranscriptionEngine.maxChunkDuration`).
    ///   - frameSize: samples per VAD frame (`VoiceActivityDetector.frameSize`).
    public init(config: ChunkPlannerConfig = .default, maxChunkDuration: TimeInterval, frameSize: Int) {
        precondition(frameSize > 0, "frameSize must be positive")
        let rate = Double(AudioFormat.sampleRate)
        func samples(_ seconds: TimeInterval) -> Int { max(0, Int((seconds * rate).rounded())) }

        self.config = config
        self.frameSize = frameSize
        paddingSamples = samples(config.padding)
        let maxSamples = max(samples(maxChunkDuration), 2 * frameSize + 2 * paddingSamples + 1)
        maxChunkSamples = maxSamples
        minSpeechBeforeCutSamples = samples(config.minSpeechBeforeCut)
        cutSilenceSamples = max(1, samples(config.cutSilence))
        // Keep forced cuts making progress whatever the settings say: the next chunk always starts at least
        // half a chunk after the previous one.
        windowSamples = min(samples(config.forcedCutSearchWindow), maxSamples / 4)
        overlapSamples = min(samples(config.forcedCutOverlap), maxSamples / 4)
        minSpeechSamples = samples(config.minSpeechToTranscribe)
        enterThreshold = config.speechThreshold
        exitThreshold = config.speechExitThreshold
    }

    /// Adds audio and VAD output. `probabilities` continues the series from earlier calls: one value per complete
    /// `frameSize`-sample frame of the recording, in order. It may lag behind the audio (frames are only planned
    /// once both have arrived). Returns the chunks that became final, in order.
    public mutating func append(samples: [Float], probabilities: [Float]) -> [AudioChunk] {
        guard !finished else { return [] }
        buffer.append(contentsOf: samples)
        for probability in probabilities { receive(probability) }
        return advance()
    }

    /// Ends the recording and returns the remaining chunks. Feed all the VAD output first: frames still without a
    /// probability (including a final partial frame) take the last probability received, or count as speech when
    /// none ever arrived, so no words are lost if the VAD fails. Later calls return nothing.
    public mutating func finish() -> [AudioChunk] {
        guard !finished else { return [] }
        finished = true
        let framesNeeded = (totalSamples + frameSize - 1) / frameSize
        let fill = lastProbability ?? 1
        while framesReceived < framesNeeded { receive(fill) }
        var chunks = advance()
        if let last = emit(cutAt: totalSamples) { chunks.append(last) }
        buffer = []
        frames = []
        return chunks
    }

    /// Plans a whole recording at once. Gives exactly what streaming the same input gives.
    public static func plan(samples: [Float], probabilities: [Float], frameSize: Int,
                            config: ChunkPlannerConfig = .default, maxChunkDuration: TimeInterval) -> [AudioChunk] {
        var planner = ChunkPlanner(config: config, maxChunkDuration: maxChunkDuration, frameSize: frameSize)
        var chunks = planner.append(samples: samples, probabilities: probabilities)
        chunks += planner.finish()
        return chunks
    }

    // MARK: - Frames

    private mutating func receive(_ probability: Float) {
        if probability >= enterThreshold {
            inSpeech = true
        } else if probability < exitThreshold {
            inSpeech = false
        }
        frames.append(Frame(probability: probability, isSpeech: inSpeech))
        lastProbability = probability
    }

    private func frame(_ index: Int) -> Frame { frames[index - framesStart] }

    private func frameEnd(_ index: Int) -> Int { min((index + 1) * frameSize, totalSamples) }

    /// Whether frame `index` has both its audio and its probability.
    private func isReady(_ index: Int) -> Bool {
        guard index < framesReceived else { return false }
        return finished ? index * frameSize < totalSamples : (index + 1) * frameSize <= totalSamples
    }

    // MARK: - Planning

    private mutating func advance() -> [AudioChunk] {
        var chunks: [AudioChunk] = []
        while isReady(nextFrame) {
            switch step(nextFrame) {
            case .next:
                nextFrame += 1
            case let .cut(end, nextStart):
                if let chunk = emit(cutAt: end) { chunks.append(chunk) }
                segment = Segment(start: nextStart)
                nextFrame = nextStart / frameSize
            }
        }
        releaseOldInput()
        return chunks
    }

    private mutating func step(_ index: Int) -> Step {
        let frameStart = index * frameSize
        let end = frameEnd(index)
        let start = max(frameStart, segment.start)
        guard start < end else { return .next }
        let isSpeech = frame(index).isSpeech

        guard let audioStart = segment.audioStart else {
            if isSpeech {
                segment.audioStart = max(segment.start, start - paddingSamples)
                segment.speechSamples = end - start
            }
            return .next
        }

        let limit = audioStart + maxChunkSamples
        if end > limit { return forcedCut(audioStart: audioStart, limit: limit) }

        if isSpeech {
            segment.speechSamples += end - start
            segment.silenceRunStart = nil
            segment.silenceRunQualified = false
            return .next
        }

        let runStart = segment.silenceRunStart ?? start
        segment.silenceRunStart = runStart
        let run = end - runStart
        guard !segment.silenceRunQualified, run >= cutSilenceSamples else { return .next }
        segment.silenceRunQualified = true
        let middle = runStart + run / 2
        if segment.speechSamples >= minSpeechBeforeCutSamples {
            return .cut(end: middle, nextStart: middle)
        }
        segment.earlySilenceCut = middle
        return .next
    }

    private func forcedCut(audioStart: Int, limit: Int) -> Step {
        if let early = segment.earlySilenceCut {
            return .cut(end: early, nextStart: early)
        }
        // Frames lying wholly inside the search window, all of which have been looked at already.
        let windowStart = max(audioStart, limit - windowSamples)
        let first = (windowStart + frameSize - 1) / frameSize
        let last = limit / frameSize - 1
        var cut = limit
        if first <= last {
            var best = first
            var lowest = frame(first).probability
            for index in stride(from: first + 1, through: last, by: 1) {
                let probability = frame(index).probability
                if probability <= lowest {
                    lowest = probability
                    best = index
                }
            }
            cut = best * frameSize + frameSize / 2
        }
        // Overlap only when cutting through speech: words there may be split, so both chunks hear them.
        guard frame((cut - 1) / frameSize).isSpeech else { return .cut(end: cut, nextStart: cut) }
        let nextStart = max(cut - overlapSamples, audioStart + 1)
        return .cut(end: cut, nextStart: nextStart)
    }

    /// Finishes the current chunk at `cutAt` (trimmed to its speech plus padding). Nil when it is dropped.
    private mutating func emit(cutAt cut: Int) -> AudioChunk? {
        guard let audioStart = segment.audioStart else { return nil }
        let cut = min(cut, audioStart + maxChunkSamples, totalSamples)
        guard let speechEnd = lastSpeechEnd(in: audioStart..<cut) else { return nil }
        let end = min(cut, speechEnd + paddingSamples)
        guard end > audioStart, speechSamples(in: audioStart..<end) >= minSpeechSamples else { return nil }
        let overlap = max(0, (lastEmittedEnd ?? 0) - audioStart)
        let chunk = AudioChunk(index: nextIndex, startSample: audioStart, endSample: end, overlapBefore: overlap,
                               samples: Array(buffer[(audioStart - bufferStart)..<(end - bufferStart)]))
        nextIndex += 1
        lastEmittedEnd = end
        return chunk
    }

    /// Where the last speech in `range` ends.
    private func lastSpeechEnd(in range: Range<Int>) -> Int? {
        guard !range.isEmpty else { return nil }
        var index = (range.upperBound - 1) / frameSize
        while index >= framesStart, index * frameSize + frameSize > range.lowerBound {
            if index < framesReceived, frame(index).isSpeech { return min(frameEnd(index), range.upperBound) }
            index -= 1
        }
        return nil
    }

    private func speechSamples(in range: Range<Int>) -> Int {
        var total = 0
        var index = range.lowerBound / frameSize
        while index * frameSize < range.upperBound, index < framesReceived {
            if frame(index).isSpeech {
                let lower = max(index * frameSize, range.lowerBound)
                let upper = min(frameEnd(index), range.upperBound)
                total += max(0, upper - lower)
            }
            index += 1
        }
        return total
    }

    /// Drops audio and frames that no later chunk can need. Amortised: only when at least half the buffer goes.
    private mutating func releaseOldInput() {
        let keepFrom = min(segment.audioStart ?? max(segment.start, nextFrame * frameSize - paddingSamples),
                           totalSamples)
        let dropSamples = keepFrom - bufferStart
        if dropSamples > 0, dropSamples * 2 >= buffer.count {
            buffer.removeFirst(dropSamples)
            bufferStart = keepFrom
        }
        let dropFrames = min(keepFrom / frameSize, nextFrame) - framesStart
        if dropFrames > 0, dropFrames * 2 >= frames.count {
            let count = min(dropFrames, frames.count)
            frames.removeFirst(count)
            framesStart += count
        }
    }
}
