import Foundation

/// A chunk, and when it would become final if the recording were being made now.
public struct ScheduledChunk: Sendable, Hashable {
    public var chunk: AudioChunk
    /// Seconds from the start of the recording at which `ChunkPlanner` would hand this chunk over.
    public var availableAt: TimeInterval

    public init(chunk: AudioChunk, availableAt: TimeInterval) {
        self.chunk = chunk
        self.availableAt = availableAt
    }
}

/// Replays a finished recording through `ChunkPlanner` as if it were arriving from the microphone, to find when each
/// chunk would become available during a live recording (PLAN §4, Phase 0 "simulates live chunking").
public enum LiveChunkSchedule {
    /// Feeds the audio one VAD frame at a time, with each frame's probability arriving with its last sample (the VAD
    /// can only score a frame once it has all of it). A chunk the planner returns after a frame is available at the
    /// end of that frame; chunks only `finish()` returns are available when the recording ends.
    ///
    /// `probabilities` holds one value per complete frame, optionally followed by one for a final partial frame
    /// (`SileroVAD.processRemainder()`). The chunks are exactly those `ChunkPlanner.plan` gives for the same input.
    public static func schedule(samples: [Float], probabilities: [Float], frameSize: Int,
                                config: ChunkPlannerConfig = .default,
                                maxChunkDuration: TimeInterval) -> [ScheduledChunk] {
        precondition(frameSize > 0, "frameSize must be positive")
        let rate = Double(AudioFormat.sampleRate)
        var planner = ChunkPlanner(config: config, maxChunkDuration: maxChunkDuration, frameSize: frameSize)
        var out: [ScheduledChunk] = []
        var position = 0
        var frame = 0
        while position < samples.count {
            let end = min(position + frameSize, samples.count)
            var frameProbabilities: [Float] = []
            if end - position == frameSize, frame < probabilities.count {
                frameProbabilities = [probabilities[frame]]
                frame += 1
            }
            let chunks = planner.append(samples: Array(samples[position..<end]), probabilities: frameProbabilities)
            out += chunks.map { ScheduledChunk(chunk: $0, availableAt: Double(end) / rate) }
            position = end
        }
        let rest = frame < probabilities.count ? Array(probabilities[frame...]) : []
        let recordingEnd = Double(samples.count) / rate
        let tail = planner.append(samples: [], probabilities: rest) + planner.finish()
        out += tail.map { ScheduledChunk(chunk: $0, availableAt: recordingEnd) }
        return out
    }
}

/// When each chunk would be transcribed during a live recording, given how long each took to transcribe.
///
/// Chunks are transcribed one at a time, in order (the engines are serial): chunk *i* starts when it is available and
/// the previous chunk is done, and the final text is ready once the last chunk is done (and never before the
/// recording ends), plus the time to stitch and fix it. **Tail latency** is how long after the end of the recording
/// that is: the wait the user feels after pressing stop.
public struct LiveTimeline: Codable, Sendable, Hashable {
    /// Seconds from the start of the recording.
    public var starts: [TimeInterval]
    public var finishes: [TimeInterval]
    public var recordingDuration: TimeInterval
    /// When the final text is ready, in seconds from the start of the recording.
    public var textReadyAt: TimeInterval

    public var tailLatency: TimeInterval { max(0, textReadyAt - recordingDuration) }

    public init(starts: [TimeInterval], finishes: [TimeInterval], recordingDuration: TimeInterval,
                textReadyAt: TimeInterval) {
        self.starts = starts
        self.finishes = finishes
        self.recordingDuration = recordingDuration
        self.textReadyAt = textReadyAt
    }

    /// - Parameters:
    ///   - availableAt: per chunk, when it becomes available (`ScheduledChunk.availableAt`).
    ///   - durations: per chunk, how long the engine took. Missing durations count as zero.
    ///   - finalisation: time after the last chunk to stitch and fix the text.
    public static func simulate(availableAt: [TimeInterval], durations: [TimeInterval],
                                recordingDuration: TimeInterval, finalisation: TimeInterval = 0) -> LiveTimeline {
        var starts: [TimeInterval] = []
        var finishes: [TimeInterval] = []
        var busyUntil: TimeInterval = 0
        for (index, available) in availableAt.enumerated() {
            let start = max(available, busyUntil)
            let finish = start + max(0, index < durations.count ? durations[index] : 0)
            starts.append(start)
            finishes.append(finish)
            busyUntil = finish
        }
        let ready = max(recordingDuration, busyUntil) + max(0, finalisation)
        return LiveTimeline(starts: starts, finishes: finishes, recordingDuration: recordingDuration, textReadyAt: ready)
    }
}
