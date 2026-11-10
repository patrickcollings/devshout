import Foundation
import Testing
@testable import DevshoutCore

/// Builds WAV files by hand, independently of `WavFormat.header`, so the parser is tested against the spec.
enum WavFixture {
    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    static func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xFF) } }

    static func file(formatTag: Int, channels: Int, rate: Int, bits: Int, data: [UInt8],
                     declaredDataSize: Int? = nil, extraChunk: Bool = false, extensible: Bool = false) -> Data {
        var bytes: [UInt8] = []
        let blockAlign = channels * bits / 8
        var fmt: [UInt8] = le16(extensible ? 0xFFFE : formatTag) + le16(channels) + le32(rate)
            + le32(rate * blockAlign) + le16(blockAlign) + le16(bits)
        if extensible {
            fmt += le16(22) + le16(bits) + le32(0x4) + le16(formatTag)
                + [0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]
        }
        bytes += Array("WAVE".utf8)
        bytes += Array("fmt ".utf8) + le32(fmt.count) + fmt
        if extraChunk {
            // An odd-length LIST chunk, which needs a pad byte.
            let info: [UInt8] = Array("INFOabc".utf8)
            bytes += Array("LIST".utf8) + le32(info.count) + info + [0]
        }
        bytes += Array("data".utf8) + le32(declaredDataSize ?? data.count) + data
        return Data(Array("RIFF".utf8) + le32(bytes.count) + bytes)
    }
}

@Suite struct WavFormatTests {
    @Test func canonicalHeaderLayout() {
        let header = WavFormat.header(sampleRate: 16_000, channels: 1, encoding: .pcm16, dataByteCount: 32_000)
        #expect(header.count == 44)
        let b = [UInt8](header)
        #expect(String(decoding: b[0..<4], as: UTF8.self) == "RIFF")
        #expect(b[4..<8].elementsEqual(WavFixture.le32(36 + 32_000)))
        #expect(String(decoding: b[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(b[16..<20].elementsEqual(WavFixture.le32(16)))
        #expect(b[20..<22].elementsEqual(WavFixture.le16(1)))          // PCM
        #expect(b[22..<24].elementsEqual(WavFixture.le16(1)))          // mono
        #expect(b[24..<28].elementsEqual(WavFixture.le32(16_000)))     // rate
        #expect(b[28..<32].elementsEqual(WavFixture.le32(32_000)))     // byte rate
        #expect(b[32..<34].elementsEqual(WavFixture.le16(2)))          // block align
        #expect(b[34..<36].elementsEqual(WavFixture.le16(16)))         // bits
        #expect(String(decoding: b[36..<40], as: UTF8.self) == "data")
        #expect(b[40..<44].elementsEqual(WavFixture.le32(32_000)))
    }

    @Test func headerRoundTrips() throws {
        let data = WavFormat.header(dataByteCount: 0) + Data(count: 10)
        let header = try WavFormat.parseHeader(data)
        #expect(header.encoding == .pcm16)
        #expect(header.sampleRate == 16_000)
        #expect(header.channels == 1)
        #expect(header.dataOffset == 44)
        // Size 0 in the header (never patched): the parser uses what the file holds.
        #expect(header.dataByteCount == 10)
        #expect(!header.dataSizeFromHeader)
    }

    @Test func patchesPointAtTheSizeFields() {
        let patches = WavFormat.headerPatches(dataByteCount: 64_000)
        #expect(patches.count == 2)
        #expect(patches[0].offset == 4)
        #expect([UInt8](patches[0].bytes) == WavFixture.le32(36 + 64_000))
        #expect(patches[1].offset == 40)
        #expect([UInt8](patches[1].bytes) == WavFixture.le32(64_000))
        // Applying them to a zero-size header gives the same bytes as building the full header.
        var header = WavFormat.header(dataByteCount: 0)
        for patch in patches {
            header.replaceSubrange(Int(patch.offset)..<Int(patch.offset) + patch.bytes.count, with: patch.bytes)
        }
        #expect(header == WavFormat.header(dataByteCount: 64_000))
    }

    @Test func oddDataSizeGetsAPadByteInTheRIFFSize() {
        #expect(WavFormat.riffChunkSize(forDataByteCount: 3) == 36 + 4)
    }

    @Test func int16ConversionClips() {
        #expect(WavFormat.int16(from: 0) == 0)
        #expect(WavFormat.int16(from: 1) == 32_767)
        #expect(WavFormat.int16(from: -1) == -32_767)
        #expect(WavFormat.int16(from: 1.5) == 32_767)
        #expect(WavFormat.int16(from: -7) == -32_767)
        #expect(WavFormat.int16(from: .infinity) == 32_767)
        #expect(WavFormat.int16(from: -.infinity) == -32_767)
        #expect(WavFormat.int16(from: .nan) == 0)
        #expect(WavFormat.int16(from: 0.5) == 16_384)
        #expect(WavFormat.float(from: -32_768) == -1)
    }

    @Test func pcm16DataIsLittleEndian() {
        let data = WavFormat.pcm16Data(from: [1, -1, 0])
        #expect([UInt8](data) == [0xFF, 0x7F, 0x01, 0x80, 0x00, 0x00])
    }

    @Test func rejectsNonWAV() {
        #expect(throws: WavError.notRIFF) { try WavFormat.parseHeader(Data("hello world, not a wav".utf8)) }
        var bytes = [UInt8](WavFormat.header())
        bytes.replaceSubrange(8..<12, with: Array("AVI ".utf8))
        #expect(throws: WavError.notWAVE) { try WavFormat.parseHeader(Data(bytes)) }
        #expect(throws: WavError.notRIFF) { try WavFormat.parseHeader(Data()) }
    }

    @Test func rejectsUnsupportedEncodings() {
        let alaw = WavFixture.file(formatTag: 6, channels: 1, rate: 8_000, bits: 8, data: [0, 0])
        #expect(throws: WavError.unsupportedFormat(formatTag: 6, bitsPerSample: 8)) { try WavFormat.parseHeader(alaw) }
    }

    @Test func missingChunks() {
        var noData = [UInt8](WavFormat.header())
        noData.removeLast(8)
        #expect(throws: WavError.missingDataChunk) { try WavFormat.parseHeader(Data(noData)) }
        let onlyRIFF = Data(Array("RIFF".utf8) + WavFixture.le32(4) + Array("WAVE".utf8))
        #expect(throws: WavError.missingFormatChunk) { try WavFormat.parseHeader(onlyRIFF) }
    }

    @Test func skipsExtraChunksAndTruncatesToWholeFrames() throws {
        // Stereo 16-bit: 4 bytes a frame; 10 bytes of data → 2 whole frames.
        let data = WavFixture.file(formatTag: 1, channels: 2, rate: 44_100, bits: 16, data: Array(repeating: 0, count: 10),
                                   extraChunk: true)
        let header = try WavFormat.parseHeader(data)
        #expect(header.channels == 2)
        #expect(header.sampleRate == 44_100)
        #expect(header.dataByteCount == 8)
        #expect(header.frameCount == 2)
        #expect(header.dataSizeFromHeader)
    }

    @Test func dataSizeLargerThanTheFileFallsBackToTheFileLength() throws {
        let data = WavFixture.file(formatTag: 1, channels: 1, rate: 16_000, bits: 16, data: [1, 0, 2, 0],
                                   declaredDataSize: 1_000_000)
        let header = try WavFormat.parseHeader(data)
        #expect(header.dataByteCount == 4)
        #expect(!header.dataSizeFromHeader)
    }

    @Test func extensibleFormatUsesTheSubFormat() throws {
        let data = WavFixture.file(formatTag: 3, channels: 1, rate: 48_000, bits: 32, data: Array(repeating: 0, count: 8),
                                   extensible: true)
        let header = try WavFormat.parseHeader(data)
        #expect(header.encoding == .float32)
        #expect(header.frameCount == 2)
    }
}
