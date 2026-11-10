import Foundation
@testable import DevshoutCore

/// An engine that "transcribes" a chunk by reading words planted in the audio: each 0.25 s block of the recording
/// whose first sample is in the chunk and loud (above 0.5) is one word, `w<block>` (block 12 starts at 3 s).
/// It records every context it was given.
final class SpikeFakeEngine: TranscriptionEngine, @unchecked Sendable {
    let id: EngineID
    let maxChunkDuration: TimeInterval
    let acceptsVocabularyPrompt: Bool
    private let lock = NSLock()
    private var _contexts: [TranscriptionContext] = []
    private var _prepared = 0
    private let delay: TimeInterval
    private let fixedText: String?

    init(id: EngineID = .parakeetV3, maxChunkDuration: TimeInterval = 14.5, delay: TimeInterval = 0,
         fixedText: String? = nil) {
        self.id = id
        self.maxChunkDuration = maxChunkDuration
        self.acceptsVocabularyPrompt = id.supportsVocabularyPrompt
        self.delay = delay
        self.fixedText = fixedText
    }

    var contexts: [TranscriptionContext] { lock.lock(); defer { lock.unlock() }; return _contexts }
    var prepared: Int { lock.lock(); defer { lock.unlock() }; return _prepared }

    func prepare(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        progress(ModelProgress(phase: .loading))
        lock.withLock { _prepared += 1 }
        progress(ModelProgress(phase: .ready, fraction: 1))
    }

    func transcribe(_ chunk: AudioChunk, context: TranscriptionContext) async throws -> ChunkTranscript {
        lock.withLock { _contexts.append(context) }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        let block = AudioFormat.sampleRate / 4
        var words: [String] = []
        var index = (chunk.startSample + block - 1) / block
        while index * block < chunk.endSample {
            let offset = index * block - chunk.startSample
            if offset < chunk.samples.count, chunk.samples[offset] > 0.5 { words.append("w\(index)") }
            index += 1
        }
        return ChunkTranscript(index: chunk.index, startSample: chunk.startSample, endSample: chunk.endSample,
                               overlapBefore: chunk.overlapBefore, text: fixedText ?? words.joined(separator: " "),
                               engine: id, elapsed: delay)
    }

    func unload() async {}
}

/// A VAD that says "speech" wherever the audio is loud: the probability of a frame is its peak level.
final class SpikeFakeVAD: VoiceActivityDetector, @unchecked Sendable {
    let frameSize: Int
    private let lock = NSLock()
    private var pending: [Float] = []

    init(frameSize: Int = 4096) { self.frameSize = frameSize }

    func prepare() async throws {}

    func process(_ samples: [Float]) async throws -> [Float] {
        lock.withLock {
            pending += samples
            var out: [Float] = []
            while pending.count >= frameSize {
                let frame = pending.prefix(frameSize)
                out.append((frame.max() ?? 0) > 0.5 ? 0.95 : 0.02)
                pending.removeFirst(frameSize)
            }
            return out
        }
    }

    /// The probability of what is left over (a partial frame), like `SileroVAD.processRemainder`.
    func remainder() -> Float? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let p: Float = (pending.max() ?? 0) > 0.5 ? 0.95 : 0.02
        pending = []
        return p
    }

    func reset() async {
        lock.withLock { pending = [] }
    }
}

enum SpikeAudio {
    static let rate = AudioFormat.sampleRate

    /// Audio made of segments: `(seconds, loud)`. Loud audio is 0.9, quiet 0.
    static func make(_ segments: [(TimeInterval, Bool)]) -> [Float] {
        var out: [Float] = []
        for (seconds, loud) in segments {
            out += [Float](repeating: loud ? 0.9 : 0, count: Int(seconds * Double(rate)))
        }
        return out
    }
}

/// A temporary folder removed when the test ends.
struct SpikeTempDir {
    let url: URL

    init(_ label: String = "spike") throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("devshout-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ text: String, to path: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
