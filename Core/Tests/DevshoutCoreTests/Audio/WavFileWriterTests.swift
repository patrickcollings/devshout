import Foundation
import Testing
@testable import DevshoutCore

@Suite struct WavFileWriterTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("devshout-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested/audio.wav")
    }

    func declaredDataSize(_ url: URL) throws -> Int {
        let bytes = [UInt8](try Data(contentsOf: url))
        return Int(bytes[40]) | Int(bytes[41]) << 8 | Int(bytes[42]) << 16 | Int(bytes[43]) << 24
    }

    @Test func writesAValidFileAndReportsDuration() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let writer = try WavFileWriter(url: url)
        let samples: [Float] = (0..<24_000).map { sin(Float($0) * 0.01) * 0.3 }
        try writer.write(Array(samples[0..<10_000]))
        try writer.write([])
        try writer.write(Array(samples[10_000...]))
        #expect(writer.sampleCount == 24_000)
        let duration = try writer.close()
        #expect(duration == 1.5)
        #expect(!writer.isOpen)
        #expect(try writer.close() == 1.5)  // Closing twice is harmless.
        #expect(throws: WavFileWriterError.closed) { try writer.write([0]) }

        let header = try WavFormat.parseHeader(try Data(contentsOf: url))
        #expect(header.dataSizeFromHeader)
        #expect(header.dataByteCount == 48_000)
        let decoded = try WavReader.read(contentsOf: url)
        #expect(decoded.samples.count == 24_000)
        #expect(zip(decoded.samples, samples).allSatisfy { abs($0 - $1) < 1e-4 })
        #expect(try Data(contentsOf: url).count == 44 + 48_000)
    }

    @Test func patchesTheHeaderWhileRecording() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let writer = try WavFileWriter(url: url, patchInterval: 1_000)
        #expect(try declaredDataSize(url) == 0)

        try writer.write([Float](repeating: 0.1, count: 600))
        #expect(try declaredDataSize(url) == 0)          // Not yet 1,000 samples since the last patch.
        try writer.write([Float](repeating: 0.1, count: 600))
        #expect(try declaredDataSize(url) == 2_400)      // Patched at 1,200 samples.
        try writer.write([Float](repeating: 0.1, count: 300))
        #expect(try declaredDataSize(url) == 2_400)

        // Without closing (as after a crash), the file still parses and the reader finds every sample on disk.
        let midway = try WavReader.read(contentsOf: url)
        #expect(midway.samples.count == 1_200)           // Header says 1,200: trusted, since it fits in the file.
        #expect(try WavReader.read(contentsOf: url, recovering: true).samples.count == 1_500)
        try writer.flush()
        #expect(try declaredDataSize(url) == 3_000)
        #expect(try WavReader.read(contentsOf: url).samples.count == 1_500)
        try writer.close()
    }

    @Test func repairsARecordingThatWasNeverClosed() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        var writer: WavFileWriter? = try WavFileWriter(url: url, patchInterval: 1_000)
        try writer?.write([Float](repeating: 0.2, count: 1_600))
        // Simulate a crash: chop off the last byte (half a sample) and never close.
        let partial = try Data(contentsOf: url)
        writer = nil
        try partial.dropLast().write(to: url)
        #expect(try declaredDataSize(url) == 3_200)

        let duration = try WavFileWriter.repairHeader(at: url)
        #expect(duration == 1_599.0 / 16_000)
        #expect(try declaredDataSize(url) == 3_198)
        #expect(try WavReader.read(contentsOf: url).samples.count == 1_599)

        try Data(WavFixture.file(formatTag: 3, channels: 1, rate: 16_000, bits: 32, data: [0, 0, 0, 0])).write(to: url)
        #expect(throws: WavFileWriterError.notADevshoutRecording) { try WavFileWriter.repairHeader(at: url) }
    }

    @Test func overwritesAnExistingFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let first = try WavFileWriter(url: url)
        try first.write([Float](repeating: 0.5, count: 5_000))
        try first.close()
        let second = try WavFileWriter(url: url)
        try second.write([0.25])
        try second.close()
        #expect(try WavReader.read(contentsOf: url).samples.count == 1)
    }
}
