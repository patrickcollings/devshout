import Foundation

/// Streams 16 kHz mono Float32 audio to a 16-bit PCM WAV file.
///
/// The header is written first with a data size of 0, then patched with the real sizes every `patchInterval` samples
/// (2 s of audio by default) and on `close()`, so a crash mid-recording leaves a valid file whose header may undercount
/// the last ~2 s. To get every sample back from a crashed recording, read it with `WavReader.read(contentsOf:recovering: true)`
/// or fix it first with `WavFileWriter.repairHeader(at:)`; a plain read trusts the stale size and drops that tail.
///
/// Foundation's `FileHandle` only, so it lives in Core and is tested on Linux. Thread-safe: every call takes a lock,
/// though the recorder only ever calls it from its own serial queue.
public final class WavFileWriter: @unchecked Sendable {
    public let url: URL
    public let sampleRate: Int
    /// Samples between header patches.
    public let patchInterval: Int

    private let lock = NSLock()
    private var handle: FileHandle?
    private var samplesWritten = 0
    private var samplesAtLastPatch = 0

    /// Creates (or truncates) the file at `url` and writes the header. Creates missing parent folders.
    public init(url: URL, sampleRate: Int = AudioFormat.sampleRate, patchInterval: Int = 2 * AudioFormat.sampleRate) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.patchInterval = max(1, patchInterval)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fileManager.createFile(atPath: url.path, contents: WavFormat.header(sampleRate: sampleRate)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.handle = handle
    }

    deinit {
        try? closeLocked()
    }

    /// Samples written so far.
    public var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return samplesWritten
    }

    public var duration: TimeInterval { Double(sampleCount) / Double(sampleRate) }

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handle != nil
    }

    /// Appends samples (clipped to −1…1) and patches the header when another `patchInterval` samples have gone by.
    public func write(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw WavFileWriterError.closed }
        try handle.write(contentsOf: WavFormat.pcm16Data(from: samples))
        samplesWritten += samples.count
        if samplesWritten - samplesAtLastPatch >= patchInterval {
            try patchHeader(handle)
        }
    }

    /// Patches the header now, without closing.
    public func flush() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        try patchHeader(handle)
        try handle.synchronize()
    }

    /// Patches the header, syncs and closes. Returns the duration in seconds. Safe to call more than once.
    @discardableResult
    public func close() throws -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        try closeLocked()
        return Double(samplesWritten) / Double(sampleRate)
    }

    private func closeLocked() throws {
        guard let handle else { return }
        self.handle = nil
        defer { try? handle.close() }
        try patchHeader(handle)
        try handle.synchronize()
    }

    private func patchHeader(_ handle: FileHandle) throws {
        for patch in WavFormat.headerPatches(dataByteCount: samplesWritten * 2) {
            try handle.seek(toOffset: patch.offset)
            try handle.write(contentsOf: patch.bytes)
        }
        try handle.seekToEnd()
        samplesAtLastPatch = samplesWritten
    }
}

extension WavFileWriter {
    /// Fixes the size fields of a recording that was never closed (the app crashed or was killed), so every sample
    /// on disk counts and other apps can open it. Returns the recording's duration. Only for devshout's own files:
    /// it expects the canonical 44-byte 16-bit PCM header the writer makes.
    @discardableResult
    public static func repairHeader(at url: URL) throws -> TimeInterval {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let header = try WavFormat.parseHeader(data, recovering: true)
        guard header.dataOffset == WavFormat.headerSize, header.encoding == .pcm16 else {
            throw WavFileWriterError.notADevshoutRecording
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for patch in WavFormat.headerPatches(dataByteCount: header.dataByteCount) {
            try handle.seek(toOffset: patch.offset)
            try handle.write(contentsOf: patch.bytes)
        }
        try handle.synchronize()
        return header.duration
    }
}

public enum WavFileWriterError: Error, Sendable, Hashable {
    case closed
    case notADevshoutRecording
}
