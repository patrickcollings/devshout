import Foundation
import Testing
@testable import DevshoutCore

@Suite struct WavReaderTests {
    @Test func encodeThenDecodeRoundTrips() throws {
        let samples: [Float] = (0..<1_000).map { sin(Float($0) * 0.05) * 0.8 }
        let decoded = try WavReader.decode(WavFormat.encode(samples))
        #expect(decoded.sampleRate == 16_000)
        #expect(decoded.sourceChannels == 1)
        #expect(decoded.sourceEncoding == .pcm16)
        #expect(decoded.samples.count == samples.count)
        for (a, b) in zip(decoded.samples, samples) {
            #expect(abs(a - b) < 1.0 / 16_000)
        }
        #expect(abs(decoded.duration - 1_000.0 / 16_000) < 1e-9)
    }

    @Test func stereoPCM16IsMixedToMono() throws {
        // Frames: (L=16384, R=0), (L=-16384, R=-16384)
        let data = WavFixture.le16(16_384) + WavFixture.le16(0) + WavFixture.le16(-16_384 & 0xFFFF) + WavFixture.le16(-16_384 & 0xFFFF)
        let decoded = try WavReader.decode(WavFixture.file(formatTag: 1, channels: 2, rate: 44_100, bits: 16, data: data))
        #expect(decoded.sampleRate == 44_100)
        #expect(decoded.sourceChannels == 2)
        #expect(decoded.samples == [0.25, -0.5])
    }

    @Test func float32MonoAndStereo() throws {
        func f32(_ v: Float) -> [UInt8] { WavFixture.le32(Int(v.bitPattern)) }
        let mono = try WavReader.decode(WavFixture.file(formatTag: 3, channels: 1, rate: 48_000, bits: 32,
                                                        data: f32(0.5) + f32(-0.25) + f32(1.5)))
        #expect(mono.sourceEncoding == .float32)
        #expect(mono.samples == [0.5, -0.25, 1.5])  // Float files are passed through unclipped.
        let stereo = try WavReader.decode(WavFixture.file(formatTag: 3, channels: 2, rate: 48_000, bits: 32,
                                                          data: f32(0.5) + f32(0.25)))
        #expect(stereo.samples == [0.375])
    }

    @Test func otherPCMWidthsAndFloat64() throws {
        let pcm8 = try WavReader.decode(WavFixture.file(formatTag: 1, channels: 1, rate: 8_000, bits: 8, data: [128, 255, 0]))
        #expect(pcm8.samples == [0, Float(127) / 128, -1])

        // 24-bit: 0x400000 = 0.5, 0xC00000 = -0.5
        let pcm24 = try WavReader.decode(WavFixture.file(formatTag: 1, channels: 1, rate: 16_000, bits: 24,
                                                         data: [0x00, 0x00, 0x40, 0x00, 0x00, 0xC0]))
        #expect(pcm24.samples == [0.5, -0.5])

        let pcm32 = try WavReader.decode(WavFixture.file(formatTag: 1, channels: 1, rate: 16_000, bits: 32,
                                                         data: WavFixture.le32(0x4000_0000)))
        #expect(pcm32.samples == [0.5])

        var f64: [UInt8] = []
        withUnsafeBytes(of: (-0.75 as Double).bitPattern.littleEndian) { f64 += $0 }
        let float64 = try WavReader.decode(WavFixture.file(formatTag: 3, channels: 1, rate: 16_000, bits: 64, data: f64))
        #expect(float64.samples == [-0.75])
    }

    @Test func readsAFileOnDiskAndResamplesTo16k() throws {
        let rate = 48_000
        let samples: [Float] = (0..<rate).map { sin(2 * .pi * 440 * Float($0) / Float(rate)) * 0.5 }
        var pcm: [UInt8] = []
        for s in samples { pcm += WavFixture.le16(Int(WavFormat.int16(from: s)) & 0xFFFF) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("devshout-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try WavFixture.file(formatTag: 1, channels: 1, rate: rate, bits: 16, data: pcm).write(to: url)

        let decoded = try WavReader.read(contentsOf: url)
        #expect(decoded.sampleRate == 48_000)
        let at16k = try WavReader.read16kMono(contentsOf: url)
        #expect(at16k.count == 16_000)
        // A 440 Hz tone keeps its level after resampling.
        let level = AudioLevel.measure(at16k)
        #expect(abs(level.rms - 0.5 / 2.0.squareRoot().float) < 0.01)
    }
}

extension Double {
    var float: Float { Float(self) }
}
