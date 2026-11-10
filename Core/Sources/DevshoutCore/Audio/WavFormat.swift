import Foundation

// WAV (RIFF/WAVE) building and parsing. devshout writes 16-bit PCM, mono, 16 kHz; it reads PCM (8/16/24/32-bit) and
// IEEE float (32/64-bit), any channel count and any sample rate, so imported files can be re-transcribed.
// Everything here is pure Foundation and little-endian, as the format requires.

/// How samples are stored in a WAV file's data chunk.
public enum WavSampleEncoding: String, Sendable, Hashable, CaseIterable {
    case pcm8, pcm16, pcm24, pcm32, float32, float64

    public var bitsPerSample: Int {
        switch self {
        case .pcm8: 8
        case .pcm16: 16
        case .pcm24: 24
        case .pcm32, .float32: 32
        case .float64: 64
        }
    }

    public var bytesPerSample: Int { bitsPerSample / 8 }
    public var isFloat: Bool { self == .float32 || self == .float64 }
}

/// What `WavFormat.parseHeader` found.
public struct WavHeader: Sendable, Hashable {
    public var encoding: WavSampleEncoding
    public var sampleRate: Int
    public var channels: Int
    /// Byte offset of the first sample.
    public var dataOffset: Int
    /// Bytes of sample data available (whole frames only). When the header's own size was missing or wrong
    /// (a writer that crashed before patching it), this is what the file actually holds.
    public var dataByteCount: Int
    /// False when the data size in the header was 0, 0xFFFFFFFF or larger than the file, and was worked out from the file length.
    public var dataSizeFromHeader: Bool

    public var bytesPerFrame: Int { encoding.bytesPerSample * channels }
    public var frameCount: Int { bytesPerFrame == 0 ? 0 : dataByteCount / bytesPerFrame }
    public var duration: TimeInterval { sampleRate == 0 ? 0 : Double(frameCount) / Double(sampleRate) }
}

public enum WavError: Error, Sendable, Hashable {
    case notRIFF
    case notWAVE
    case missingFormatChunk
    case missingDataChunk
    case unsupportedFormat(formatTag: Int, bitsPerSample: Int)
    case invalidFormat(String)
}

/// A value to write at a byte offset of a WAV file, used to patch its size fields while recording.
public struct WavHeaderPatch: Sendable, Hashable {
    public var offset: UInt64
    public var bytes: Data

    public init(offset: UInt64, bytes: Data) {
        self.offset = offset
        self.bytes = bytes
    }
}

public enum WavFormat {
    /// Size of the canonical header devshout writes (RIFF + fmt + data chunk headers).
    public static let headerSize = 44
    /// Byte offset of the RIFF chunk size (file length − 8).
    public static let riffSizeOffset: UInt64 = 4
    /// Byte offset of the data chunk size, in the canonical 44-byte header.
    public static let dataSizeOffset: UInt64 = 40

    static let formatTagPCM = 1
    static let formatTagFloat = 3
    static let formatTagExtensible = 0xFFFE

    // MARK: Building

    /// A canonical 44-byte header. `dataByteCount` is 0 for a file that is still being written.
    public static func header(sampleRate: Int = AudioFormat.sampleRate, channels: Int = 1,
                              encoding: WavSampleEncoding = .pcm16, dataByteCount: Int = 0) -> Data {
        let blockAlign = channels * encoding.bytesPerSample
        var data = Data(capacity: headerSize)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLE(riffChunkSize(forDataByteCount: dataByteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(encoding.isFloat ? formatTagFloat : formatTagPCM))
        data.appendLE(UInt16(channels))
        data.appendLE(UInt32(sampleRate))
        data.appendLE(UInt32(sampleRate * blockAlign))
        data.appendLE(UInt16(blockAlign))
        data.appendLE(UInt16(encoding.bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.appendLE(clampedUInt32(dataByteCount))
        return data
    }

    /// The RIFF chunk size for a canonical header followed by `dataByteCount` bytes of samples.
    public static func riffChunkSize(forDataByteCount dataByteCount: Int) -> UInt32 {
        clampedUInt32(headerSize - 8 + dataByteCount + (dataByteCount & 1))
    }

    /// The two size fields to rewrite once `dataByteCount` bytes of samples follow a canonical header.
    public static func headerPatches(dataByteCount: Int) -> [WavHeaderPatch] {
        var riff = Data()
        riff.appendLE(riffChunkSize(forDataByteCount: dataByteCount))
        var dataSize = Data()
        dataSize.appendLE(clampedUInt32(dataByteCount))
        return [WavHeaderPatch(offset: riffSizeOffset, bytes: riff), WavHeaderPatch(offset: dataSizeOffset, bytes: dataSize)]
    }

    /// Float32 in −1…1 to Int16, clipping anything outside that range. NaN becomes 0.
    @inlinable
    public static func int16(from sample: Float) -> Int16 {
        guard !sample.isNaN else { return 0 }
        let clipped = min(max(sample, -1), 1)
        return Int16((clipped * 32767).rounded())
    }

    /// Int16 to Float32 in −1…1.
    @inlinable
    public static func float(from sample: Int16) -> Float {
        Float(sample) / 32768
    }

    /// Little-endian 16-bit PCM bytes for `samples`, clipped.
    public static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            for (i, sample) in samples.enumerated() {
                raw.storeBytes(of: int16(from: sample).littleEndian, toByteOffset: i * 2, as: Int16.self)
            }
        }
        return data
    }

    /// A complete 16-bit PCM mono WAV file in memory.
    public static func encode(_ samples: [Float], sampleRate: Int = AudioFormat.sampleRate) -> Data {
        var data = header(sampleRate: sampleRate, channels: 1, encoding: .pcm16, dataByteCount: samples.count * 2)
        data.append(pcm16Data(from: samples))
        return data
    }

    // MARK: Parsing

    /// Finds the fmt and data chunks. Tolerates extra chunks (LIST, fact, …), WAVE_FORMAT_EXTENSIBLE, and a data size
    /// that was never patched (0 or 0xFFFFFFFF) or that runs past the end of the file.
    ///
    /// `recovering: true` is for devshout's own recordings after a crash: it ignores the data size in the header and
    /// takes everything to the end of the file, since the writer may have appended up to ~2 s since its last patch.
    /// Don't use it on other files, which may have chunks after the data.
    ///
    /// `fileSize` is for when `data` is only the start of the file (the header is all that's needed for the
    /// duration): the length of the whole file, which the data chunk is measured against. Nil means `data` is the
    /// whole file.
    public static func parseHeader(_ data: Data, recovering: Bool = false, fileSize: Int? = nil) throws -> WavHeader {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> WavHeader in
            guard raw.count >= 12, fourCC(raw, 0) == "RIFF" else { throw WavError.notRIFF }
            guard fourCC(raw, 8) == "WAVE" else { throw WavError.notWAVE }

            var offset = 12
            var format: (tag: Int, channels: Int, rate: Int, bits: Int)?
            while offset + 8 <= raw.count {
                let id = fourCC(raw, offset)
                let declared = Int(readUInt32(raw, offset + 4))
                let body = offset + 8
                if id == "fmt " {
                    guard declared >= 16, body + 16 <= raw.count else { throw WavError.invalidFormat("fmt chunk too short") }
                    var tag = Int(readUInt16(raw, body))
                    let channels = Int(readUInt16(raw, body + 2))
                    let rate = Int(readUInt32(raw, body + 4))
                    let bits = Int(readUInt16(raw, body + 14))
                    if tag == formatTagExtensible, declared >= 40, body + 26 <= raw.count {
                        // The sub-format GUID starts with the real format tag.
                        tag = Int(readUInt16(raw, body + 24))
                    }
                    format = (tag, channels, rate, bits)
                } else if id == "data" {
                    guard let format else { throw WavError.missingFormatChunk }
                    let encoding = try sampleEncoding(tag: format.tag, bits: format.bits)
                    guard format.channels > 0 else { throw WavError.invalidFormat("no channels") }
                    guard format.rate > 0 else { throw WavError.invalidFormat("sample rate is 0") }
                    let available = max(0, (fileSize ?? raw.count) - body)
                    let fromHeader = !recovering && declared != 0 && declared != 0xFFFF_FFFF && declared <= available
                    var byteCount = fromHeader ? declared : available
                    let frameBytes = encoding.bytesPerSample * format.channels
                    byteCount -= byteCount % frameBytes
                    return WavHeader(encoding: encoding, sampleRate: format.rate, channels: format.channels,
                                     dataOffset: body, dataByteCount: byteCount, dataSizeFromHeader: fromHeader)
                }
                // Chunks are padded to an even length.
                let next = body + declared + (declared & 1)
                guard next > offset else { break }
                offset = next
            }
            throw format == nil ? WavError.missingFormatChunk : WavError.missingDataChunk
        }
    }

    static func sampleEncoding(tag: Int, bits: Int) throws -> WavSampleEncoding {
        switch (tag, bits) {
        case (formatTagPCM, 8): return .pcm8
        case (formatTagPCM, 16): return .pcm16
        case (formatTagPCM, 24): return .pcm24
        case (formatTagPCM, 32): return .pcm32
        case (formatTagFloat, 32): return .float32
        case (formatTagFloat, 64): return .float64
        default: throw WavError.unsupportedFormat(formatTag: tag, bitsPerSample: bits)
        }
    }

    static func clampedUInt32(_ value: Int) -> UInt32 {
        UInt32(clamping: max(0, value))
    }

    static func fourCC(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> String {
        String(decoding: raw[offset..<offset + 4], as: UTF8.self)
    }

    static func readUInt16(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    static func readUInt32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
