import Foundation

/// The little we need from a WAV header: enough to give a recovered recording its duration.
public struct WAVInfo: Sendable, Hashable {
    public var sampleRate: Int
    public var channels: Int
    public var bitsPerSample: Int
    /// Bytes of sample data. Taken from the file size when the header was never patched (a crash mid-recording).
    public var dataBytes: Int

    public var duration: TimeInterval {
        let bytesPerSecond = sampleRate * channels * max(1, bitsPerSample / 8)
        guard bytesPerSecond > 0 else { return 0 }
        return Double(dataBytes) / Double(bytesPerSecond)
    }

    /// Reads the header of a RIFF/WAVE file. Returns `nil` when it isn't one.
    public static func read(_ url: URL) -> WAVInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The header is small; 4 KB covers any extra chunks (LIST, fact, …) a writer might add.
        guard let head = try? handle.read(upToCount: 4096) else { return nil }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        return parse(header: head, fileSize: fileSize ?? head.count)
    }

    /// Parses a header (the start of the file is enough). `fileSize` is used when the data chunk's size is missing
    /// or larger than the file. A size that is present and fits is trusted, so for a recording that was never closed
    /// run `WavFileWriter.repairHeader(at:)` first. The parsing itself is `WavFormat.parseHeader`.
    public static func parse(header: Data, fileSize: Int) -> WAVInfo? {
        // Rebased, so a slice of a larger Data parses from its own first byte.
        guard let parsed = try? WavFormat.parseHeader(Data(header), fileSize: fileSize) else { return nil }
        return WAVInfo(sampleRate: parsed.sampleRate, channels: parsed.channels,
                       bitsPerSample: parsed.encoding.bitsPerSample, dataBytes: parsed.dataByteCount)
    }
}
