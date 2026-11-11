import Foundation
import Testing
@testable import DevshoutCore

/// A detector that fails from its nth call on.
private final class FailingVAD: VoiceActivityDetector, @unchecked Sendable {
    let inner = SpikeFakeVAD()
    let failFromCall: Int
    private let calls = Locked(0)
    let resets = Locked(0)

    init(failFromCall: Int) { self.failFromCall = failFromCall }

    var frameSize: Int { inner.frameSize }
    func prepare() async throws {}
    func process(_ samples: [Float]) async throws -> [Float] {
        let call = calls.mutate { count -> Int in
            count += 1
            return count
        }
        if call >= failFromCall { throw FakeError(message: "VAD exploded") }
        return try await inner.process(samples)
    }
    func reset() async {
        resets.mutate { $0 += 1 }
        await inner.reset()
    }
}

@Suite struct VADChunkPlannerTests {
    /// Speech with pauses, a stretch too long for one chunk, and a last partial frame.
    static let audio = SpikeAudio.make([(0.4, false), (4, true), (1, false), (5, true), (1.2, false), (20, true),
                                        (0.8, false), (3.3, true), (0.31, false)])
    static let frame = 4096

    /// What planning the whole recording in one go gives (the detector over all of it, then `ChunkPlanner.plan`).
    static func batch(_ samples: [Float], max: TimeInterval = 14.5) async throws -> [AudioChunk] {
        let vad = SpikeFakeVAD()
        var probabilities = try await vad.process(samples)
        if let last = vad.remainder() { probabilities.append(last) }
        return ChunkPlanner.plan(samples: samples, probabilities: probabilities, frameSize: vad.frameSize,
                                 maxChunkDuration: max)
    }

    static func planner(_ vad: SpikeFakeVAD?, max: TimeInterval = 14.5, defers: Bool = false) -> VADChunkPlanner {
        VADChunkPlanner(maxChunkDuration: max, frameSize: frame, defersUntilFinish: defers) {
            vad.map { vad in VADChunkPlanner.Detector(vad: vad, remainder: { vad.remainder() }) }
        }
    }

    /// Feeds `samples` in buffers of `size` and returns the chunks each `append` gave, then those `finish` gave.
    static func stream(_ samples: [Float], into planner: VADChunkPlanner,
                       size: Int) async -> (live: [AudioChunk], tail: [AudioChunk]) {
        var live: [AudioChunk] = []
        var position = 0
        while position < samples.count {
            let end = min(position + size, samples.count)
            live += await planner.append(Array(samples[position..<end]))
            position = end
        }
        return (live, await planner.finish())
    }

    @Test(arguments: [160, 1_365, 4_096, 5_000, 50_000])
    func streamingGivesTheChunksOfPlanningTheWholeRecording(size: Int) async throws {
        let expected = try await Self.batch(Self.audio)
        #expect(expected.count >= 4)
        #expect(expected.contains { $0.overlapBefore > 0 })
        let streamed = await Self.stream(Self.audio, into: Self.planner(SpikeFakeVAD()), size: size)
        #expect(streamed.live + streamed.tail == expected)
        // All but the tail were handed over while the recording was still going on.
        #expect(streamed.tail.count == 1)
    }

    @Test func aChunkIsHandedOverAsSoonAsItsPauseHasBeenHeard() async {
        // 4 s of speech from 0.4 s, then a pause: the cut is made once 0.6 s of the pause has been heard.
        let planner = Self.planner(SpikeFakeVAD())
        var firstChunkAt: Int?
        var position = 0
        while position < Self.audio.count, firstChunkAt == nil {
            let end = min(position + 1_600, Self.audio.count)
            if await !planner.append(Array(Self.audio[position..<end])).isEmpty { firstChunkAt = end }
            position = end
        }
        #expect((firstChunkAt ?? 0) > Int(5.0 * 16_000))
        #expect((firstChunkAt ?? .max) <= Int(5.4 * 16_000))
    }

    @Test func deferringHandsEverythingOverAtTheEnd() async throws {
        let streamed = await Self.stream(Self.audio, into: Self.planner(SpikeFakeVAD(), defers: true), size: 1_600)
        #expect(streamed.live.isEmpty)
        #expect(try await streamed.tail == Self.batch(Self.audio))
    }

    @Test func withoutADetectorEveryFrameIsSpeech() async {
        let expected = ChunkPlanner.plan(samples: Self.audio, probabilities: [], frameSize: Self.frame,
                                         maxChunkDuration: 14.5)
        let streamed = await Self.stream(Self.audio, into: Self.planner(nil), size: 1_600)
        #expect(streamed.live + streamed.tail == expected)
        // Fixed-length chunks, cut while recording, covering the whole recording.
        #expect(streamed.live.count >= 2)
        #expect(expected.first?.startSample == 0)
        #expect(expected.last?.endSample == Self.audio.count)
        #expect(expected.dropFirst().allSatisfy { $0.overlapBefore > 0 })
    }

    @Test func aDetectorThatFailsPartWayLosesNothing() async {
        // The detector scores the first 8 s, then fails for good: the rest counts as speech.
        let vad = FailingVAD(failFromCall: 81)
        let planner = VADChunkPlanner(maxChunkDuration: 14.5, frameSize: Self.frame) {
            VADChunkPlanner.Detector(vad: vad)
        }
        let streamed = await Self.stream(Self.audio, into: planner, size: 1_600)
        let chunks = streamed.live + streamed.tail
        #expect(chunks.map(\.index) == Array(0..<chunks.count))
        // The first pause was still found.
        #expect(chunks.first?.startSample == max(0, Self.frame - 2_400))
        #expect((chunks.first?.endSample ?? 0) < Int(5 * 16_000))
        // From the failure on nothing is left out: every later chunk meets or overlaps the one before, to the end.
        #expect(chunks.last?.endSample == Self.audio.count)
        for (previous, next) in zip(chunks.dropFirst(), chunks.dropFirst(2)) {
            #expect(next.startSample <= previous.endSample)
        }
        #expect(vad.resets.get() == 1)
    }

    @Test func theDetectorIsResetForEachRecording() async throws {
        // The shared detector still holds part of a frame from the recording before.
        let vad = SpikeFakeVAD()
        _ = try await vad.process([Float](repeating: 0.9, count: 1_000))
        let streamed = await Self.stream(Self.audio, into: Self.planner(vad), size: 1_600)
        #expect(try await streamed.live + streamed.tail == Self.batch(Self.audio))
    }

    @Test func anEmptyRecordingHasNoChunks() async {
        let planner = Self.planner(SpikeFakeVAD())
        #expect(await planner.finish().isEmpty)
        let silent = Self.planner(SpikeFakeVAD())
        let streamed = await Self.stream([Float](repeating: 0, count: 40_000), into: silent, size: 1_600)
        #expect(streamed.live.isEmpty && streamed.tail.isEmpty)
    }
}
