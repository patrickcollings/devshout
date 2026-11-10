import Foundation

/// Decoded audio: mono Float32 samples at the file's own sample rate.
public struct DecodedAudio: Sendable, Hashable {
    /// Mono samples in −1…1 (several channels are averaged).
    public var samples: [Float]
    public var sampleRate: Int
    /// Channels in the source before mixing down to mono.
    public var sourceChannels: Int
    public var sourceEncoding: WavSampleEncoding

    public init(samples: [Float], sampleRate: Int, sourceChannels: Int = 1, sourceEncoding: WavSampleEncoding = .pcm16) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.sourceChannels = sourceChannels
        self.sourceEncoding = sourceEncoding
    }

    public var duration: TimeInterval { sampleRate == 0 ? 0 : Double(samples.count) / Double(sampleRate) }

    /// The samples at 16 kHz (`AudioFormat.sampleRate`), resampled when the file used another rate.
    public func samplesAt16kHz() -> [Float] {
        LinearResampler.resample(samples, from: sampleRate, to: AudioFormat.sampleRate)
    }
}

/// Reads WAV files into mono Float32. Accepts every encoding `WavSampleEncoding` lists, any channel count and any rate.
public enum WavReader {
    /// `recovering`: see `WavFormat.parseHeader(_:recovering:)` (for devshout's own recordings after a crash).
    public static func decode(_ data: Data, recovering: Bool = false) throws -> DecodedAudio {
        let header = try WavFormat.parseHeader(data, recovering: recovering)
        let channels = header.channels
        let frames = header.frameCount
        let bytesPerSample = header.encoding.bytesPerSample
        var mono = [Float](repeating: 0, count: frames)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = header.dataOffset
            let scale = 1 / Float(channels)
            mono.withUnsafeMutableBufferPointer { out in
                for frame in 0..<frames {
                    var sum: Float = 0
                    let frameStart = base + frame * header.bytesPerFrame
                    for channel in 0..<channels {
                        sum += sample(raw, at: frameStart + channel * bytesPerSample, encoding: header.encoding)
                    }
                    out[frame] = channels == 1 ? sum : sum * scale
                }
            }
        }
        return DecodedAudio(samples: mono, sampleRate: header.sampleRate, sourceChannels: channels,
                            sourceEncoding: header.encoding)
    }

    public static func read(contentsOf url: URL, recovering: Bool = false) throws -> DecodedAudio {
        try decode(Data(contentsOf: url, options: .mappedIfSafe), recovering: recovering)
    }

    /// 16 kHz mono samples, ready for an engine.
    public static func read16kMono(contentsOf url: URL, recovering: Bool = false) throws -> [Float] {
        try read(contentsOf: url, recovering: recovering).samplesAt16kHz()
    }

    @inline(__always)
    static func sample(_ raw: UnsafeRawBufferPointer, at offset: Int, encoding: WavSampleEncoding) -> Float {
        switch encoding {
        case .pcm8:
            // 8-bit WAV is unsigned, centred on 128.
            return (Float(raw[offset]) - 128) / 128
        case .pcm16:
            return WavFormat.float(from: Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
        case .pcm24:
            let value = Int32(raw[offset]) | Int32(raw[offset + 1]) << 8 | Int32(Int8(bitPattern: raw[offset + 2])) << 16
            return Float(value) / 8_388_608
        case .pcm32:
            let value = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int32.self))
            return Float(Double(value) / 2_147_483_648)
        case .float32:
            let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            return Float(bitPattern: bits)
        case .float64:
            let bits = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            return Float(Double(bitPattern: bits))
        }
    }
}
