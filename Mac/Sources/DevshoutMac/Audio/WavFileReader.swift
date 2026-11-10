// Loads audio files as 16 kHz mono Float32: for re-transcribing recordings from history and for devshout-cli.
//
// WAV goes through Core's tolerant parser first (it reads devshout's own crash-truncated files, which AVAudioFile may
// refuse). Anything else (m4a, mp3, aiff, caf, flac) goes through AVAudioFile. Resampling uses AVAudioConverter, with
// Core's LinearResampler as a fallback.
//
// Unsure on macOS (not compiled in CI yet):
// - AVAudioFile.read(into:) reading a whole long file in one call (fine for minutes of audio; hours would want slices).
import AVFoundation
import DevshoutCore
import Foundation

public enum WavFileReaderError: Error, LocalizedError {
    case unreadable(URL, String)
    case couldNotCreateBuffer

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url, let reason): return "Couldn't read \(url.lastPathComponent): \(reason)"
        case .couldNotCreateBuffer: return "Couldn't allocate an audio buffer."
        }
    }
}

public enum WavFileReader {
    /// The file as 16 kHz mono Float32, whatever its format.
    /// - Parameter recovering: for devshout's own recordings after a crash: read every sample on disk even when the
    ///   header's size is stale (see `WavFormat.parseHeader(_:recovering:)`).
    public static func read16kMono(_ url: URL, recovering: Bool = false) throws -> [Float] {
        let decoded: DecodedAudio
        do {
            decoded = try WavReader.read(contentsOf: url, recovering: recovering)
        } catch let wavError as WavError {
            // Not a WAV we can parse ourselves (or not a WAV at all): let Core Audio try.
            do {
                return try readWithAVFoundation(url)
            } catch {
                throw WavFileReaderError.unreadable(url, "\(error.localizedDescription) (WAV parser: \(wavError))")
            }
        }
        return resampleTo16k(decoded)
    }

    /// The decoded file at its own rate, mono, with details about the source. WAV only.
    public static func readWav(_ url: URL, recovering: Bool = false) throws -> DecodedAudio {
        try WavReader.read(contentsOf: url, recovering: recovering)
    }

    /// Duration in seconds, read from the header only.
    public static func duration(of url: URL) throws -> TimeInterval {
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            // The fmt chunk is near the start, but the data chunk may follow other chunks: 64 KB covers real files.
            if let head = try handle.read(upToCount: 65_536), var header = try? WavFormat.parseHeader(head),
               header.dataOffset >= 4, header.dataOffset <= head.count {
                // The parser only saw the first 64 KB, so check the declared data size against the whole file.
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                let available = max(0, size - header.dataOffset)
                let sizeBytes = [UInt8](head[(head.startIndex + header.dataOffset - 4)..<(head.startIndex + header.dataOffset)])
                let declared = sizeBytes.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
                let usable = (declared != 0 && declared != 0xFFFF_FFFF && declared <= available) ? declared : available
                header.dataByteCount = usable - usable % max(1, header.bytesPerFrame)
                return header.duration
            }
        }
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    static func resampleTo16k(_ audio: DecodedAudio) -> [Float] {
        if audio.sampleRate == AudioFormat.sampleRate { return audio.samples }
        if let converted = try? StreamingResampler.resample(audio.samples, from: Double(audio.sampleRate)) {
            return converted
        }
        return audio.samplesAt16kHz()
    }

    static func readWithAVFoundation(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw WavFileReaderError.couldNotCreateBuffer
        }
        try file.read(into: buffer)
        let mono = buffer.monoFloatSamples()
        return resampleTo16k(DecodedAudio(samples: mono, sampleRate: Int(format.sampleRate.rounded()),
                                          sourceChannels: Int(format.channelCount), sourceEncoding: .float32))
    }
}
