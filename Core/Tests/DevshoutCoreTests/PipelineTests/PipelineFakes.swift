import Foundation
@testable import DevshoutCore

// Fakes for every protocol the pipeline uses. Each keeps what it was asked behind a lock so tests can inspect it.

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func mutate<R>(_ body: (inout Value) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

struct FakeError: Error, LocalizedError, Hashable {
    var message: String
    var errorDescription: String? { message }
}

/// A temporary folder, removed by `remove()`.
struct TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("devshout-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

final class FixedDateSource: DateSource, @unchecked Sendable {
    private let current: Locked<Date>
    init(_ date: Date) { current = Locked(date) }
    func now() -> Date { current.get() }
    func advance(_ seconds: TimeInterval) { current.mutate { $0 = $0.addingTimeInterval(seconds) } }
}

enum TestWAV {
    /// A 16-bit PCM mono WAV. `patchSizes: false` leaves the RIFF and data sizes at 0, as a crash would.
    static func data(sampleCount: Int, sampleRate: Int = 16_000, patchSizes: Bool = true) -> Data {
        var data = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; data.append(Data(bytes: &x, count: 2)) }
        let dataBytes = sampleCount * 2
        data.append(contentsOf: Array("RIFF".utf8)); u32(patchSizes ? 36 + dataBytes : 0)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2)
        u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(patchSizes ? dataBytes : 0)
        data.append(Data(count: dataBytes))
        return data
    }
}

final class FakeRecorder: AudioRecorder, @unchecked Sendable {
    let buffers: [[Float]]
    /// Yielded during `stop()`, before the stream finishes (the recorder's last flush).
    let tailBuffers: [[Float]]
    let startError: FakeError?
    let stopError: FakeError?
    /// When false, `stop()` never finishes the stream (a badly behaved recorder).
    let finishesStream: Bool
    /// Seconds `start` takes (AVAudioEngine start-up, a Bluetooth microphone switching profile).
    let startDelay: TimeInterval

    let startedURL = Locked<URL?>(nil)
    let stopped = Locked(false)
    let cancelled = Locked(false)
    private let continuation = Locked<AsyncStream<[Float]>.Continuation?>(nil)

    init(buffers: [[Float]] = [[Float](repeating: 0.1, count: 16_000)], tailBuffers: [[Float]] = [],
         startError: FakeError? = nil, stopError: FakeError? = nil, finishesStream: Bool = true,
         startDelay: TimeInterval = 0) {
        self.buffers = buffers
        self.tailBuffers = tailBuffers
        self.startError = startError
        self.stopError = stopError
        self.finishesStream = finishesStream
        self.startDelay = startDelay
    }

    var totalSamples: Int { (buffers + tailBuffers).reduce(0) { $0 + $1.count } }

    func start(writingTo fileURL: URL) async throws -> AsyncStream<[Float]> {
        if startDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000)) }
        if let startError { throw startError }
        startedURL.mutate { $0 = fileURL }
        try TestWAV.data(sampleCount: totalSamples).write(to: fileURL)
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        for buffer in buffers { continuation.yield(buffer) }
        self.continuation.mutate { $0 = continuation }
        return stream
    }

    func stop() async throws -> TimeInterval {
        stopped.mutate { $0 = true }
        let continuation = self.continuation.get()
        for buffer in tailBuffers { continuation?.yield(buffer) }
        if finishesStream { continuation?.finish() }
        if let stopError { throw stopError }
        return Double(totalSamples) / 16_000
    }

    func cancel() async {
        cancelled.mutate { $0 = true }
        continuation.get()?.finish()
    }
}

final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    let id: EngineID
    let maxChunkDuration: TimeInterval = 14.5
    let acceptsVocabularyPrompt: Bool
    /// What happens on each call for a chunk index, in order; when they run out (or for other chunks) the call
    /// succeeds. `[.fail, .fail]` fails the chunk and its retry; `[.fail]` fails once and then works.
    let script: [Int: [Step]]
    let calls = Locked<[(index: Int, context: TranscriptionContext)]>([])

    enum Step: Sendable {
        case fail
        /// Never answers, like a stuck Core ML call. Ignores cancellation.
        case hang
        /// Answers with no text (silence, or a cough).
        case empty
    }

    init(id: EngineID = .parakeetV3, acceptsVocabularyPrompt: Bool = false, failAtIndex: Int? = nil,
         script: [Int: [Step]] = [:]) {
        self.id = id
        self.acceptsVocabularyPrompt = acceptsVocabularyPrompt
        var script = script
        if let failAtIndex { script[failAtIndex] = [.fail, .fail] }
        self.script = script
    }

    func prepare(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {}
    func unload() async {}

    func transcribe(_ chunk: AudioChunk, context: TranscriptionContext) async throws -> ChunkTranscript {
        let attempt = calls.mutate { calls -> Int in
            calls.append((chunk.index, context))
            return calls.filter { $0.index == chunk.index }.count - 1
        }
        var text = "part \(chunk.index)"
        if let steps = script[chunk.index], attempt < steps.count {
            switch steps[attempt] {
            case .fail:
                throw FakeError(message: "engine exploded")
            case .hang:
                // A dispatch timer rather than Task.sleep, so cancellation doesn't end it (see FakeCleaner.hanging).
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 30) { c.resume() }
                }
                throw FakeError(message: "answered far too late")
            case .empty:
                text = ""
            }
        }
        return ChunkTranscript(index: chunk.index, startSample: chunk.startSample, endSample: chunk.endSample,
                               text: text, engine: id, elapsed: 0.01)
    }

    var calledIndices: [Int] { calls.get().map(\.index) }
}

final class FakeCleaner: TextCleaner, @unchecked Sendable {
    typealias Behaviour = @Sendable (String, ModeConfig, String) async throws -> CleanResult
    let behaviour: Behaviour
    let calls = Locked<[(raw: String, mode: ModeConfig, glossary: String)]>([])

    init(_ behaviour: @escaping Behaviour = { raw, mode, _ in
        CleanResult(text: "Cleaned: \(raw)", model: mode.claudeModel, elapsed: 0.5, warnings: ["note"])
    }) {
        self.behaviour = behaviour
    }

    func clean(_ raw: String, mode: ModeConfig, glossary: String) async throws -> CleanResult {
        calls.mutate { $0.append((raw, mode, glossary)) }
        return try await behaviour(raw, mode, glossary)
    }

    static func failing(_ error: CleanError) -> FakeCleaner { FakeCleaner { _, _, _ in throw error } }

    static func hanging() -> FakeCleaner {
        FakeCleaner { raw, mode, _ in
            // Ignores cancellation on purpose: the session mustn't wait for it.
            // A dispatch timer, not Task.sleep: after cancellation Task.sleep throws at once, which would spin.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { c.resume() }
            }
            return CleanResult(text: "too late", model: mode.claudeModel, elapsed: 10)
        }
    }
}

final class FakeDeliverer: Deliverer, @unchecked Sendable {
    let outcome: DeliveryOutcome
    let delivered = Locked<[String]>([])
    init(outcome: DeliveryOutcome = .pasted(appName: "Slack")) { self.outcome = outcome }
    func deliver(_ text: String) async -> DeliveryOutcome {
        delivered.mutate { $0.append(text) }
        return outcome
    }
}

/// A session wired to fakes, with a temporary history root.
struct SessionHarness {
    let temp: TempDir
    let recorder: FakeRecorder
    let engine: FakeEngine
    let cleaner: FakeCleaner
    let deliverer: FakeDeliverer
    let history: HistoryStore
    let session: DictationSession
    let plannedSampleCounts = Locked<[Int]>([])
    let stitchedIndices = Locked<[[Int]]>([])

    init(recorder: FakeRecorder = FakeRecorder(),
         engine: FakeEngine = FakeEngine(),
         cleaner: FakeCleaner = FakeCleaner(),
         deliverer: FakeDeliverer = FakeDeliverer(),
         settings: AppSettings = AppSettings(),
         options: DictationOptions = DictationOptions(),
         chunkOrder: [Int] = [0, 1, 2],
         planError: FakeError? = nil) throws {
        temp = try TempDir()
        self.recorder = recorder
        self.engine = engine
        self.cleaner = cleaner
        self.deliverer = deliverer
        let dates = FixedDateSource(Date(timeIntervalSince1970: 1_793_000_000))
        history = HistoryStore(root: temp.url.appendingPathComponent("Recordings"), dateSource: dates,
                               timeZone: TimeZone(identifier: "UTC")!)
        let planned = plannedSampleCounts
        let stitched = stitchedIndices
        let deps = DictationDependencies(
            recorder: recorder,
            engine: engine,
            cleaner: cleaner,
            deliverer: deliverer,
            history: history,
            planChunks: { samples in
                planned.mutate { $0.append(samples.count) }
                if let planError { throw planError }
                // Each chunk is 14.5 s of the recording, as Parakeet's are.
                return chunkOrder.map { AudioChunk(index: $0, startSample: $0 * 232_000, endSample: ($0 + 1) * 232_000,
                                                   samples: [Float](repeating: 0, count: 100)) }
            },
            stitch: { transcripts in
                stitched.mutate { $0.append(transcripts.map(\.index)) }
                return transcripts.map(\.text).joined(separator: " ")
            },
            fixText: { $0.replacingOccurrences(of: "part", with: "Part") },
            glossaryForClaude: { "## Terms\n- CORSIA" },
            vocabularyPrompt: { "CORSIA, NDC" },
            dateSource: dates)
        session = DictationSession(dependencies: deps, settings: settings, options: options)
    }

    /// Waits (briefly) until the session has collected `seconds` of audio.
    func waitForAudio(_ seconds: TimeInterval) async {
        for _ in 0..<1_000 {
            if case .recording(let elapsed, _) = await session.state, elapsed >= seconds { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Collects every state until the stream finishes.
    static func collect(_ stream: AsyncStream<SessionState>) async -> [SessionState] {
        var states: [SessionState] = []
        for await state in stream { states.append(state) }
        return states
    }
}
