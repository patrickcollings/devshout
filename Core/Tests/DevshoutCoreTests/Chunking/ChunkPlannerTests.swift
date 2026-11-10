import Foundation
import Testing
@testable import DevshoutCore

/// Synthetic VAD series for the planner. Frames are 4,096 samples (256 ms), as FluidAudio's Silero VAD gives.
/// With the defaults that means: padding 2,400 samples, a natural cut needs 3 silent frames (≥ 0.6 s) after
/// 12 speech frames (≥ 3 s), and a chunk with one speech frame (0.256 s ≥ 0.25 s) is kept.
struct Scenario {
    static let frame = 4096
    static let speech: Float = 0.9
    static let silence: Float = 0.05

    var probabilities: [Float] = []
    /// Extra samples after the last whole frame (a partial frame with no probability).
    var tailSamples = 0

    func with(_ frames: Int, _ probability: Float) -> Scenario {
        var copy = self
        copy.probabilities += Array(repeating: probability, count: frames)
        return copy
    }
    func speech(_ frames: Int) -> Scenario { with(frames, Self.speech) }
    func silence(_ frames: Int) -> Scenario { with(frames, Self.silence) }

    var sampleCount: Int { probabilities.count * Self.frame + tailSamples }
    /// Each sample holds its own position, so chunk contents can be checked exactly (Float is exact to 2^24).
    var samples: [Float] { (0..<sampleCount).map(Float.init) }

    func plan(max: TimeInterval = 14.5, config: ChunkPlannerConfig = .default) -> [AudioChunk] {
        ChunkPlanner.plan(samples: samples, probabilities: probabilities, frameSize: Self.frame, config: config,
                          maxChunkDuration: max)
    }
}

private let pad = 2400
private let frame = Scenario.frame

private func checkInvariants(_ chunks: [AudioChunk], total: Int, max maxDuration: TimeInterval = 14.5,
                             sourceLocation: SourceLocation = #_sourceLocation) {
    let maxSamples = Int(maxDuration * 16_000)
    var previousEnd: Int?
    for (position, chunk) in chunks.enumerated() {
        #expect(chunk.index == position, sourceLocation: sourceLocation)
        #expect(chunk.startSample >= 0 && chunk.endSample <= total, sourceLocation: sourceLocation)
        #expect(chunk.endSample > chunk.startSample, sourceLocation: sourceLocation)
        #expect(chunk.endSample - chunk.startSample <= maxSamples, sourceLocation: sourceLocation)
        #expect(chunk.samples.count == chunk.endSample - chunk.startSample, sourceLocation: sourceLocation)
        #expect(chunk.samples.first == Float(chunk.startSample), sourceLocation: sourceLocation)
        #expect(chunk.samples.last == Float(chunk.endSample - 1), sourceLocation: sourceLocation)
        let expectedOverlap = max(0, (previousEnd ?? 0) - chunk.startSample)
        #expect(chunk.overlapBefore == expectedOverlap, sourceLocation: sourceLocation)
        if let previousEnd { #expect(chunk.endSample > previousEnd, sourceLocation: sourceLocation) }
        previousEnd = chunk.endSample
    }
}

@Suite struct ChunkPlannerConfigTests {
    @Test func defaultsMatchThePlan() {
        let config = ChunkPlannerConfig.default
        #expect(config.minSpeechBeforeCut == 3)
        #expect(config.cutSilence == 0.6)
        #expect(config.speechThreshold == 0.3)
        #expect(config.speechExitOffset == 0.15)
        #expect(abs(config.speechExitThreshold - 0.15) < 0.0001)
        #expect(config.forcedCutSearchWindow == 2)
        #expect(config.forcedCutOverlap == 1)
        #expect(config.minSpeechToTranscribe == 0.25)
        #expect(config.padding == 0.15)
    }

    @Test func roundTripsThroughJSON() throws {
        let config = ChunkPlannerConfig(minSpeechBeforeCut: 4, cutSilence: 0.8, speechThreshold: 0.5,
                                        speechExitOffset: 0.1, forcedCutSearchWindow: 3, forcedCutOverlap: 0.5,
                                        minSpeechToTranscribe: 0.4, padding: 0.2)
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(ChunkPlannerConfig.self, from: data) == config)
    }

    @Test func missingKeysTakeDefaults() throws {
        let decoded = try JSONDecoder().decode(ChunkPlannerConfig.self, from: Data(#"{"cutSilence": 1.2}"#.utf8))
        var expected = ChunkPlannerConfig.default
        expected.cutSilence = 1.2
        #expect(decoded == expected)
        #expect(try JSONDecoder().decode(ChunkPlannerConfig.self, from: Data("{}".utf8)) == .default)
    }
}

@Suite struct ChunkPlannerTests {
    @Test func naturalCutsGoInTheSilenceWithPadding() {
        let scenario = Scenario().silence(2).speech(15).silence(5).speech(15).silence(5)
        let chunks = scenario.plan()
        #expect(chunks.count == 2)
        guard chunks.count == 2 else { return }
        // Speech in frames 2...16; silence from 17; the cut is due once frame 19 ends (3 silent frames).
        #expect(chunks[0].startSample == 2 * frame - pad)
        #expect(chunks[0].endSample == 17 * frame + pad)
        #expect(chunks[1].startSample == 22 * frame - pad)
        #expect(chunks[1].endSample == 37 * frame + pad)
        #expect(chunks.allSatisfy { $0.overlapBefore == 0 })
        checkInvariants(chunks, total: scenario.sampleCount)
    }

    @Test func naturalCutIsEmittedAsSoonAsTheSilenceQualifies() {
        let scenario = Scenario().speech(15).silence(40)
        var planner = ChunkPlanner(maxChunkDuration: 14.5, frameSize: frame)
        let samples = scenario.samples
        // Feed up to the end of the second silent frame: not enough silence yet.
        var chunks = planner.append(samples: Array(samples[0..<(17 * frame)]),
                                    probabilities: Array(scenario.probabilities[0..<17]))
        #expect(chunks.isEmpty)
        chunks = planner.append(samples: Array(samples[(17 * frame)..<(18 * frame)]),
                                probabilities: [scenario.probabilities[17]])
        #expect(chunks.count == 1)
        #expect(chunks.first?.endSample == 15 * frame + pad)
        #expect(planner.finish().isEmpty)
    }

    @Test func noCutBeforeEnoughSpeech() {
        // 2 s of speech, a pause, 2 s more: too little speech before the pause for a natural cut.
        let scenario = Scenario().silence(1).speech(8).silence(4).speech(8).silence(2)
        let chunks = scenario.plan()
        #expect(chunks.count == 1)
        #expect(chunks.first?.startSample == frame - pad)
        #expect(chunks.first?.endSample == 21 * frame + pad)
        checkInvariants(chunks, total: scenario.sampleCount)
    }

    @Test func shortSilenceDoesNotCut() {
        // Two silent frames (0.512 s) is under the 0.6 s needed.
        let scenario = Scenario().speech(15).silence(2).speech(15)
        let chunks = scenario.plan()
        #expect(chunks.count == 1)
        #expect(chunks.first?.startSample == 0)
        #expect(chunks.first?.endSample == scenario.sampleCount)
    }

    @Test func hysteresisKeepsTheCurrentState() {
        // 0.2 is between the exit (0.15) and entry (0.3) thresholds: it continues speech and continues silence.
        let scenario = Scenario().with(10, 0.2).speech(15).with(10, 0.2).speech(15).silence(4)
        let chunks = scenario.plan()
        #expect(chunks.count == 1)
        #expect(chunks.first?.startSample == 10 * frame - pad)
        #expect(chunks.first?.endSample == 50 * frame + pad)
        // A dip below 0.15 does end speech.
        let dipped = Scenario().speech(15).with(4, 0.1).speech(15).silence(4).plan()
        #expect(dipped.count == 2)
    }

    @Test func forcedCutAtTheMaximumWithOverlap() {
        let scenario = Scenario().speech(120)
        let chunks = scenario.plan()
        #expect(chunks.count >= 2)
        guard chunks.count >= 2 else { return }
        // Limit 232,000 samples; the search window covers frames 49...55, all equal, so the latest wins and the cut
        // goes in the middle of frame 55.
        #expect(chunks[0].startSample == 0)
        #expect(chunks[0].endSample == 55 * frame + frame / 2)
        #expect(chunks[1].startSample == chunks[0].endSample - 16_000)
        #expect(chunks[1].overlapBefore == 16_000)
        #expect(chunks.last?.endSample == scenario.sampleCount)
        checkInvariants(chunks, total: scenario.sampleCount)
    }

    @Test func forcedCutGoesAtTheLowestProbabilityFrame() {
        var probabilities = Array(repeating: Scenario.speech, count: 100)
        probabilities[30] = 0.31 // lower, but outside the last 2 s before the limit
        probabilities[50] = 0.6
        probabilities[52] = 0.4  // the lowest inside the window
        probabilities[54] = 0.5
        probabilities[56] = 0.2  // lower still, but past the limit
        let scenario = Scenario(probabilities: probabilities)
        let chunks = scenario.plan()
        #expect(chunks.first?.endSample == 52 * frame + frame / 2)
        #expect(chunks.dropFirst().first?.overlapBefore == 16_000)
        checkInvariants(chunks, total: scenario.sampleCount)
    }

    @Test func forcedCutThroughSilenceHasNoOverlap() {
        // One frame below the exit threshold is too short for a natural cut, but it is the lowest point in the
        // window and nothing is being said there, so the next chunk needs no overlap.
        var probabilities = Array(repeating: Scenario.speech, count: 100)
        probabilities[53] = 0.1
        let scenario = Scenario(probabilities: probabilities)
        let chunks = scenario.plan()
        #expect(chunks.count >= 2)
        guard chunks.count >= 2 else { return }
        #expect(chunks[0].endSample == 53 * frame + frame / 2)
        #expect(chunks[1].startSample == 53 * frame + frame / 2)
        #expect(chunks[1].overlapBefore == 0)
        checkInvariants(chunks, total: scenario.sampleCount)
    }

    @Test func forcedCutPrefersAnEarlierPause() {
        // 2 s of speech, a 1 s pause (too early for a natural cut), then 17 s without a break.
        let scenario = Scenario().speech(8).silence(4).speech(70)
        let chunks = scenario.plan()
        #expect(chunks.count >= 2)
        guard chunks.count >= 2 else { return }
        #expect(chunks[0].startSample == 0)
        #expect(chunks[0].endSample == 8 * frame + pad)
        #expect(chunks[1].startSample == 12 * frame - pad)
        #expect(chunks[1].overlapBefore == 0)
        checkInvariants(chunks, total: scenario.sampleCount)
    }

    @Test func whisperLengthChunks() {
        let scenario = Scenario().speech(400)
        let chunks = scenario.plan(max: 28)
        checkInvariants(chunks, total: scenario.sampleCount, max: 28)
        #expect(chunks.dropLast().allSatisfy { $0.duration > 26 })
    }

    @Test func fiveMinutesWithoutSilence() {
        let total = 5 * 60 * 16_000 // 4.8M samples: 1,171 whole frames and a partial one
        let probabilities = Array(repeating: Scenario.speech, count: total / frame)
        let samples = (0..<total).map(Float.init)
        let started = Date()
        let chunks = ChunkPlanner.plan(samples: samples, probabilities: probabilities, frameSize: frame,
                                       maxChunkDuration: 14.5)
        let elapsed = Date().timeIntervalSince(started)
        checkInvariants(chunks, total: total)
        #expect(chunks.first?.startSample == 0)
        #expect(chunks.last?.endSample == total)
        #expect(chunks.dropFirst().allSatisfy { $0.overlapBefore == 16_000 })
        #expect(chunks.dropLast().allSatisfy { $0.duration > 13.5 && $0.duration <= 14.5 })
        #expect(chunks.count == 23)
        #expect(elapsed < 10, "planning 5 minutes took \(elapsed) s")
    }

    @Test func fiveMinutesStreamedInSmallBuffers() {
        // A real recording arrives in ~100 ms buffers with the VAD a frame or two behind.
        let scenario = (0..<20).reduce(Scenario()) { $0.speech(40 + $1 % 7).silence($1 % 3 == 0 ? 2 : 5) }
            .speech(300)
        let samples = scenario.samples
        let started = Date()
        var planner = ChunkPlanner(maxChunkDuration: 14.5, frameSize: frame)
        var chunks: [AudioChunk] = []
        var fedProbabilities = 0
        var position = 0
        while position < samples.count {
            let end = min(position + 1600, samples.count)
            let lagging = max(0, end / frame - 2)
            chunks += planner.append(samples: Array(samples[position..<end]),
                                     probabilities: Array(scenario.probabilities[fedProbabilities..<lagging]))
            fedProbabilities = lagging
            position = end
        }
        chunks += planner.append(samples: [], probabilities: Array(scenario.probabilities[fedProbabilities...]))
        chunks += planner.finish()
        let elapsed = Date().timeIntervalSince(started)
        #expect(chunks == scenario.plan())
        checkInvariants(chunks, total: samples.count)
        #expect(elapsed < 10, "streaming took \(elapsed) s")
    }

    @Test func silenceOnlyGivesNothing() {
        #expect(Scenario().silence(1200).plan().isEmpty)
        #expect(Scenario().plan().isEmpty)
        #expect(ChunkPlanner.plan(samples: [], probabilities: [], frameSize: frame, maxChunkDuration: 14.5).isEmpty)
    }

    @Test func aSingleSpeechFrameIsEnough() {
        // "Yes": one VAD frame (0.256 s) of speech in a short recording. It used to be dropped as no speech.
        let one = Scenario().silence(3).speech(1).silence(3).plan()
        #expect(one.count == 1)
        #expect(one.first?.startSample == 3 * frame - pad)
        #expect(one.first?.endSample == 4 * frame + pad)
        // The same at the very start and the very end of a recording, where there is no room for padding.
        #expect(Scenario().speech(1).silence(3).plan().map(\.startSample) == [0])
        #expect(Scenario().silence(3).speech(1).plan().map(\.endSample) == [4 * frame])
        #expect(Scenario().speech(1).plan().count == 1)
    }

    @Test func tooLittleSpeechIsDropped() {
        // With a minimum above one frame, one speech frame (0.256 s) is dropped; two frames (0.512 s) are enough.
        let strict = ChunkPlannerConfig(minSpeechToTranscribe: 0.3)
        #expect(Scenario().silence(10).speech(1).silence(10).plan(config: strict).isEmpty)
        let two = Scenario().silence(10).speech(2).silence(10).plan(config: strict)
        #expect(two.count == 1)
        #expect(two.first?.startSample == 10 * frame - pad)
        #expect(two.first?.endSample == 12 * frame + pad)
    }

    @Test func droppedChunksKeepIndexesConsecutive() {
        // A cough after the first chunk, then 20 s of silence: the cough's chunk is cut at the limit and dropped.
        let scenario = Scenario().speech(15).silence(4).speech(1).silence(80).speech(15).silence(4)
        let chunks = scenario.plan(config: ChunkPlannerConfig(minSpeechToTranscribe: 0.3))
        #expect(chunks.map(\.index) == [0, 1])
        #expect(chunks.last?.startSample == 100 * frame - pad)
        #expect(chunks.last?.overlapBefore == 0)
        checkInvariants(chunks, total: scenario.sampleCount)
    }

    @Test func longPausesAreNotSent() {
        // Speech, 30 s of silence, speech: the silence belongs to neither chunk.
        let scenario = Scenario().speech(15).silence(117).speech(15)
        let chunks = scenario.plan()
        #expect(chunks.count == 2)
        #expect(chunks.first?.endSample == 15 * frame + pad)
        #expect(chunks.last?.startSample == 132 * frame - pad)
        #expect(chunks.allSatisfy { $0.duration < 4.5 })
    }

    @Test func paddingIsClampedAtTheEdges() {
        let scenario = Scenario().speech(15)
        let chunks = scenario.plan()
        #expect(chunks.count == 1)
        #expect(chunks.first?.startSample == 0)
        #expect(chunks.first?.endSample == scenario.sampleCount)
    }

    @Test func finishCoversFramesTheVADHasNotReported() {
        // 30 frames of audio but probabilities for only 20 (all speech): the rest counts as speech too.
        let scenario = Scenario().speech(20)
        var planner = ChunkPlanner(maxChunkDuration: 14.5, frameSize: frame)
        #expect(planner.append(samples: (0..<(30 * frame)).map(Float.init), probabilities: scenario.probabilities)
            .isEmpty)
        let chunks = planner.finish()
        #expect(chunks.count == 1)
        #expect(chunks.first?.endSample == 30 * frame)
        #expect(planner.finish().isEmpty)
        #expect(planner.append(samples: [1, 2, 3], probabilities: [1]).isEmpty)
    }

    @Test func finishAfterSilenceDoesNotInventSpeech() {
        let scenario = Scenario().speech(15).silence(2)
        var planner = ChunkPlanner(maxChunkDuration: 14.5, frameSize: frame)
        _ = planner.append(samples: (0..<(40 * frame)).map(Float.init), probabilities: scenario.probabilities)
        let chunks = planner.finish()
        #expect(chunks.count == 1)
        #expect(chunks.first?.endSample == 15 * frame + pad)
    }

    @Test func withoutAnyVADOutputEverythingIsTranscribed() {
        let total = 40 * 16_000
        let chunks = ChunkPlanner.plan(samples: (0..<total).map(Float.init), probabilities: [], frameSize: frame,
                                       maxChunkDuration: 14.5)
        checkInvariants(chunks, total: total)
        #expect(chunks.first?.startSample == 0)
        #expect(chunks.last?.endSample == total)
    }

    @Test func partialFinalFrameIsIncluded() {
        var scenario = Scenario().speech(20)
        scenario.tailSamples = 1000
        let chunks = scenario.plan()
        #expect(chunks.count == 1)
        #expect(chunks.first?.endSample == 20 * frame + 1000)
        checkInvariants(chunks, total: scenario.sampleCount)
    }

    @Test func otherFrameSizes() {
        // 512-sample frames (32 ms), as Silero can also run.
        let small = 512
        var probabilities = Array(repeating: Float(0.05), count: 50)
        probabilities += Array(repeating: 0.9, count: 200) + Array(repeating: 0.05, count: 40)
        probabilities += Array(repeating: 0.9, count: 900)
        let total = probabilities.count * small
        let chunks = ChunkPlanner.plan(samples: (0..<total).map(Float.init), probabilities: probabilities,
                                       frameSize: small, maxChunkDuration: 14.5)
        checkInvariants(chunks, total: total)
        #expect(chunks.first?.startSample == 50 * small - pad)
        #expect(chunks.first?.endSample == 250 * small + pad)
        #expect(chunks.dropFirst().first?.overlapBefore == 0)
        #expect(chunks.last?.endSample == total)
    }

    @Test func extremeSettingsStillTerminate() {
        let config = ChunkPlannerConfig(minSpeechBeforeCut: 0, cutSilence: 0, forcedCutSearchWindow: 100,
                                        forcedCutOverlap: 100, minSpeechToTranscribe: 0, padding: 0)
        let scenario = Scenario().speech(50).silence(3).speech(200)
        for max in [0.1, 1.0, 14.5] {
            let chunks = scenario.plan(max: max, config: config)
            #expect(!chunks.isEmpty)
            #expect(chunks.last?.endSample == scenario.sampleCount)
        }
    }

    // One case at a time, and each kept light (30 to 90 s of audio; the five-minute tests above cover long
    // recordings). Swift Testing runs every test and every case on Swift's task threads, of which a CI runner has
    // two. These cases are plain CPU work that never suspends, and in parallel at 75 to 220 s of audio each they
    // held both threads for over 20 s; any async test waiting on a timer or a child process could not resume until
    // they were done, and the ones that timed themselves failed.
    @Test(.serialized, arguments: 0..<40)
    func streamingMatchesBatch(seed: UInt64) {
        var random = SplitMix64(seed: seed)
        var scenario = Scenario()
        while scenario.probabilities.count < 120 + Int(seed) * 6 {
            let kind = random.next(below: 4)
            let length = 1 + random.next(below: kind == 0 ? 80 : 12)
            switch kind {
            case 0: scenario = scenario.speech(length)
            case 1: scenario = scenario.silence(length)
            case 2: scenario = scenario.with(length, Float(random.next(below: 1000)) / 1000)
            default: scenario = scenario.with(length, Float(random.next(below: 300)) / 1000 + 0.1)
            }
        }
        scenario.tailSamples = random.next(below: frame)
        let max = [14.5, 28, 5][Int(seed % 3)]
        let samples = scenario.samples
        let batch = ChunkPlanner.plan(samples: samples, probabilities: scenario.probabilities, frameSize: frame,
                                      maxChunkDuration: max)
        checkInvariants(batch, total: scenario.sampleCount, max: max)

        var planner = ChunkPlanner(maxChunkDuration: max, frameSize: frame)
        var streamed: [AudioChunk] = []
        var position = 0
        var fed = 0
        while position < samples.count {
            let end = min(samples.count, position + 1 + random.next(below: 20_000))
            // The VAD reports a random number of the frames it has audio for.
            let available = min(end / frame, scenario.probabilities.count)
            let upTo = fed + random.next(below: available - fed + 1)
            streamed += planner.append(samples: Array(samples[position..<end]),
                                       probabilities: Array(scenario.probabilities[fed..<upTo]))
            fed = upTo
            position = end
        }
        streamed += planner.append(samples: [], probabilities: Array(scenario.probabilities[fed...]))
        streamed += planner.finish()
        #expect(streamed == batch)
    }
}

/// A small seedable generator, so the randomised tests are repeatable.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(below bound: Int) -> Int { bound <= 0 ? 0 : Int(next() % UInt64(bound)) }
}
