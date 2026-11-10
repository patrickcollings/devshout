import Foundation
import Testing
@testable import DevshoutCore

@Suite struct LinearResamplerTests {
    func tone(_ frequency: Float, rate: Int, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(Double(rate) * seconds)).map { amplitude * sin(2 * .pi * frequency * Float($0) / Float(rate)) }
    }

    @Test func sameRateIsUntouched() {
        let x: [Float] = [0.1, 0.2, 0.3]
        #expect(LinearResampler.resample(x, from: 16_000, to: 16_000) == x)
    }

    @Test(arguments: [(48_000, 16_000), (44_100, 16_000), (8_000, 16_000), (22_050, 16_000), (96_000, 16_000)])
    func lengthsMatchTheRatio(from: Int, to: Int) {
        let x = [Float](repeating: 0.1, count: from)  // one second
        let y = LinearResampler.resample(x, from: from, to: to)
        #expect(y.count == to)
        // A constant stays constant, whichever way.
        #expect(y.allSatisfy { abs($0 - 0.1) < 1e-5 })
    }

    @Test func upsamplingInterpolatesLinearly() {
        let y = LinearResampler.resample([0, 1, 0], from: 8_000, to: 16_000)
        #expect(y == [0, 0.5, 1, 0.5, 0, 0])
    }

    @Test func downsamplingAveragesEachSpan() {
        // 3:1. Output 1 covers source [1.5, 4.5): half of x[1], x[2], x[3], half of x[4].
        let x: [Float] = [0, 3, 6, 9, 12, 15]
        let y = LinearResampler.resample(x, from: 48_000, to: 16_000)
        #expect(y.count == 2)
        #expect(abs(y[0] - 1) < 1e-5)     // [0, 1.5): x[0] + half of x[1] → (0 + 1.5) / 1.5
        #expect(abs(y[1] - 7.5) < 1e-5)   // (1.5 + 6 + 9 + 6) / 3
    }

    @Test func speechBandTonesSurviveDownsampling() {
        let y = LinearResampler.resample(tone(1_000, rate: 48_000, seconds: 1), from: 48_000, to: 16_000)
        let rms = AudioLevel.measure(Array(y[100..<15_900])).rms
        #expect(abs(rms - 0.5 / Float(2).squareRoot()) < 0.02)
    }

    @Test func tonesAboveTheNewNyquistAreAttenuated() {
        // 7.9 kHz is nearly at 16 kHz's Nyquist; 20 kHz (inaudible at 16 kHz) would alias. The box filter should cut it.
        let y = LinearResampler.resample(tone(20_000, rate: 48_000, seconds: 1), from: 48_000, to: 16_000)
        let rms = AudioLevel.measure(Array(y[100..<15_900])).rms
        #expect(rms < 0.2)
    }

    @Test func degenerateInputs() {
        #expect(LinearResampler.resample([], from: 48_000, to: 16_000).isEmpty)
        #expect(LinearResampler.resample([1], from: 0, to: 16_000).isEmpty)
        #expect(LinearResampler.resample([1, 2], from: 48_000, to: 16_000).isEmpty)  // less than one output sample
        #expect(LinearResampler.outputCount(forInputCount: 44_100 * 300, from: 44_100, to: 16_000) == 16_000 * 300)
    }
}

@Suite struct AudioLevelTests {
    @Test func silenceAndEmpty() {
        #expect(AudioLevel.measure([]) == .silent)
        #expect(AudioLevel.measure([0, 0, 0]) == .silent)
        #expect(AudioLevel.silent.rmsDecibels() == -80)
        #expect(AudioLevel.silent.meterValue() == 0)
    }

    @Test func rmsAndPeak() {
        let level = AudioLevel.measure([0.5, -0.5, 0.5, -0.5])
        #expect(level.rms == 0.5)
        #expect(level.peak == 0.5)
        #expect(abs(level.rmsDecibels() - (-6.0206)) < 0.001)
        #expect(abs(level.meterValue(floor: -60) - (1 - 6.0206 / 60)) < 0.001)
    }

    @Test func clippingAndNaNAreContained() {
        let level = AudioLevel.measure([2, -3, .nan])
        #expect(level.peak == 1)
        #expect(level.rms == 1)
        #expect(AudioLevel(rms: 1, peak: 1).meterValue() == 1)
    }

    @Test func smootherRisesFastAndFallsSlowly() {
        var smoother = LevelSmoother(attack: 0.5, release: 0.1)
        #expect(smoother.update(1) == 0.5)
        #expect(smoother.update(1) == 0.75)
        let falling = smoother.update(0)
        #expect(abs(falling - 0.675) < 1e-6)
        smoother.reset()
        #expect(smoother.value == 0)
        #expect(smoother.update(.nan) == 0)
    }
}

@Suite struct FrameAccumulatorTests {
    @Test func cutsIntoFramesAndKeepsTheRest() {
        var acc = FrameAccumulator(frameSize: 4)
        #expect(acc.append([1, 2, 3]).isEmpty)
        #expect(acc.pending == [1, 2, 3])
        #expect(acc.append([4, 5, 6, 7, 8, 9, 10]) == [[1, 2, 3, 4], [5, 6, 7, 8]])
        #expect(acc.pending == [9, 10])
        #expect(acc.emittedSamples == 8)
        #expect(acc.append([]) == [])
        #expect(acc.append([11, 12]) == [[9, 10, 11, 12]])
        #expect(acc.pending.isEmpty)
        #expect(acc.append([1, 2, 3, 4, 5, 6, 7, 8]) == [[1, 2, 3, 4], [5, 6, 7, 8]])
        #expect(acc.append([0]).isEmpty)
        #expect(acc.drain() == [0])
        #expect(acc.pending.isEmpty)
        acc.reset()
        #expect(acc.emittedSamples == 0)
    }

    @Test func manySmallBuffersMatchOneBigOne() {
        let all = (0..<10_000).map(Float.init)
        var whole = FrameAccumulator(frameSize: 4_096)
        let expected = whole.append(all)
        var pieces = FrameAccumulator(frameSize: 4_096)
        var got: [[Float]] = []
        var i = 0
        var size = 1
        while i < all.count {
            let end = min(i + size, all.count)
            got += pieces.append(Array(all[i..<end]))
            i = end
            size = size * 3 % 1_031 + 1
        }
        #expect(got == expected)
        #expect(pieces.pending == whole.pending)
    }
}
