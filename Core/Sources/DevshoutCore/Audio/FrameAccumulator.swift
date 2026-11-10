import Foundation

/// Cuts a stream of arbitrarily sized buffers into fixed-size frames, keeping the leftover for the next call.
/// Used to feed the VAD, which wants exactly `frameSize` samples at a time.
public struct FrameAccumulator: Sendable, Hashable {
    public let frameSize: Int
    public private(set) var pending: [Float] = []
    /// Samples handed out in complete frames so far.
    public private(set) var emittedSamples: Int = 0

    public init(frameSize: Int) {
        precondition(frameSize > 0, "frameSize must be positive")
        self.frameSize = frameSize
        pending.reserveCapacity(frameSize)
    }

    /// Adds `samples` and returns every frame that is now complete, in order.
    public mutating func append(_ samples: [Float]) -> [[Float]] {
        var frames: [[Float]] = []
        var index = samples.startIndex
        if !pending.isEmpty {
            let take = min(frameSize - pending.count, samples.count)
            pending.append(contentsOf: samples[index..<index + take])
            index += take
            guard pending.count == frameSize else { return [] }
            frames.append(pending)
            pending.removeAll(keepingCapacity: true)
        }
        while samples.endIndex - index >= frameSize {
            frames.append(Array(samples[index..<index + frameSize]))
            index += frameSize
        }
        pending.append(contentsOf: samples[index...])
        emittedSamples += frames.count * frameSize
        return frames
    }

    /// Returns what is buffered (fewer than `frameSize` samples, possibly none) and empties the buffer.
    public mutating func drain() -> [Float] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        emittedSamples = 0
    }
}
