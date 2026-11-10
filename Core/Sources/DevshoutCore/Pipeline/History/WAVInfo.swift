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

    /// Parses a header. `fileSize` is used when the data chunk's size is missing or larger than the file.
    public static func parse(header: Data, fileSize: Int) -> WAVInfo? {
        let bytes = [UInt8](header)
        func fourCC(_ at: Int) -> String { String(decoding: bytes[at..<at + 4], as: UTF8.self) }
        guard bytes.count >= 12, fourCC(0) == "RIFF", fourCC(8) == "WAVE" else { return nil }

        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }

        var offset = 12
        var sampleRate: Int?
        var channels: Int?
        var bits: Int?
        while offset + 8 <= bytes.count {
            let id = fourCC(offset)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " {
                guard body + 16 <= bytes.count else { return nil }
                channels = u16(body + 2)
                sampleRate = u32(body + 4)
                bits = u16(body + 14)
            } else if id == "data" {
                guard let sampleRate, let channels, let bits else { return nil }
                let available = max(0, fileSize - body)
                let dataBytes = (size == 0 || size > available) ? available : size
                return WAVInfo(sampleRate: sampleRate, channels: channels, bitsPerSample: bits, dataBytes: dataBytes)
            }
            offset = body + size + (size & 1)  // chunks are word-aligned
        }
        return nil
    }
}
