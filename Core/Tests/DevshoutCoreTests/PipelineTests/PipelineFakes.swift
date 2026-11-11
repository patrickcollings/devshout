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

/// A call that never returns, whatever happens to its task: a stuck Core ML call, a `claude` that never answers.
///
/// It really is for ever (nothing resumes it), so a test's result can't depend on how long the hang lasts compared
/// with a timer that may fire late on a busy machine. The continuations are kept so that they aren't reported as
/// leaked; the suspended tasks cost nothing and end with the test process.
enum Hang {
    private static let parked = Locked<[CheckedContinuation<Never, Never>]>([])

    static func forever() async -> Never {
        await withCheckedContinuation { (continuation: CheckedContinuation<Never, Never>) in
            parked.mutate { $0.append(continuation) }
        }
    }
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

    /// More audio from the microphone while recording.
    func send(_ buffer: [Float]) {
        continuation.get()?.yield(buffer)
    }
}

/// Closed until `open()`: holds a fake's call until the test lets it go.
final class Gate: @unchecked Sendable {
    private let state = Locked<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isOpen = state.mutate { state -> Bool in
                if !state.isOpen { state.waiters.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.mutate { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// A planner with a script: `live` chunks are handed over while recording, each once that many samples have
/// arrived, and `tail` chunks when the recording ends.
final class FakePlanner: LiveChunkPlanner, @unchecked Sendable {
    let live: [(afterSamples: Int, chunk: AudioChunk)]
    let tail: [AudioChunk]
    /// Thrown by `finish()`.
    let finishError: FakeError?
    /// Thrown by `append` once this many samples have arrived (the detector failing mid-recording).
    let failsAfterSamples: Int?
    /// Never answers, like a stuck VAD call.
    let hangs: Bool

    let receivedSamples = Locked(0)
    /// The samples received by the time `finish()` was called (one entry per call).
    let finishedWithSamples = Locked<[Int]>([])
    private let handedOver = Locked(0)

    init(live: [(afterSamples: Int, chunk: AudioChunk)] = [], tail: [AudioChunk] = [], finishError: FakeError? = nil,
         failsAfterSamples: Int? = nil, hangs: Bool = false) {
        self.live = live
        self.tail = tail
        self.finishError = finishError
        self.failsAfterSamples = failsAfterSamples
        self.hangs = hangs
    }

    /// Chunk `index` of a recording cut every 14.5 s, as Parakeet's are.
    static func chunk(_ index: Int) -> AudioChunk {
        AudioChunk(index: index, startSample: index * 232_000, endSample: (index + 1) * 232_000,
                   samples: [Float](repeating: 0, count: 100))
    }

    func append(_ samples: [Float]) async throws -> [AudioChunk] {
        if hangs { await Hang.forever() }
        let received = receivedSamples.mutate { total -> Int in
            total += samples.count
            return total
        }
        if let failsAfterSamples, received >= failsAfterSamples { throw FakeError(message: "VAD failed") }
        return handedOver.mutate { next -> [AudioChunk] in
            var chunks: [AudioChunk] = []
            while next < live.count, live[next].afterSamples <= received {
                chunks.append(live[next].chunk)
                next += 1
            }
            return chunks
        }
    }

    func finish() async throws -> [AudioChunk] {
        finishedWithSamples.mutate { $0.append(receivedSamples.get()) }
        if hangs { await Hang.forever() }
        if let finishError { throw finishError }
        // Live chunks the recording ended before reaching are part of the tail.
        let rest = handedOver.mutate { next -> [AudioChunk] in
            defer { next = live.count }
            return live[next...].map(\.chunk)
        }
        return rest + tail
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
        /// Answers once the gate is opened (a call the test wants to catch in flight).
        case hold(Gate)
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
                await Hang.forever()
            case .empty:
                text = ""
            case .hold(let gate):
                await gate.wait()
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
        // Ignores cancellation on purpose: the session mustn't wait for it.
        FakeCleaner { _, _, _ in await Hang.forever() }
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
    let anyEngine: any TranscriptionEngine
    /// The scripted engine (the default).
    var engine: FakeEngine { anyEngine as! FakeEngine }
    let cleaner: FakeCleaner
    let deliverer: FakeDeliverer
    let history: HistoryStore
    let session: DictationSession
    let planner: any LiveChunkPlanner
    let stitchedIndices = Locked<[[Int]]>([])

    /// The scripted planner (nil when the harness was given another one).
    var fakePlanner: FakePlanner? { planner as? FakePlanner }
    /// The samples the planner had been given when the recording ended.
    var plannedSampleCounts: [Int] { fakePlanner?.finishedWithSamples.get() ?? [] }

    /// - Parameters:
    ///   - chunkOrder: the chunks the planner hands over, as indices.
    ///   - liveAfter: sample counts at which the first of those chunks are handed over while recording, one each.
    ///     The rest (all of them, by default) come when the recording ends, so nothing is transcribed before stop.
    ///   - planner: used instead of the scripted planner (`chunkOrder`, `liveAfter` and the `plan…` arguments).
    init(recorder: FakeRecorder = FakeRecorder(),
         engine: any TranscriptionEngine = FakeEngine(),
         cleaner: FakeCleaner = FakeCleaner(),
         deliverer: FakeDeliverer = FakeDeliverer(),
         settings: AppSettings = AppSettings(),
         options: DictationOptions = DictationOptions(),
         chunkOrder: [Int] = [0, 1, 2],
         liveAfter: [Int] = [],
         planError: FakeError? = nil,
         planFailsAfterSamples: Int? = nil,
         planHangs: Bool = false,
         planner: (any LiveChunkPlanner)? = nil,
         stitch: (@Sendable ([ChunkTranscript]) -> String)? = nil) throws {
        temp = try TempDir()
        self.recorder = recorder
        self.anyEngine = engine
        self.cleaner = cleaner
        self.deliverer = deliverer
        let dates = FixedDateSource(Date(timeIntervalSince1970: 1_793_000_000))
        history = HistoryStore(root: temp.url.appendingPathComponent("Recordings"), dateSource: dates,
                               timeZone: TimeZone(identifier: "UTC")!)
        let chunks = chunkOrder.map(FakePlanner.chunk)
        let live = zip(liveAfter, chunks).map { (afterSamples: $0, chunk: $1) }
        let planner = planner ?? FakePlanner(live: live, tail: Array(chunks.dropFirst(live.count)),
                                             finishError: planError, failsAfterSamples: planFailsAfterSamples,
                                             hangs: planHangs)
        self.planner = planner
        let stitched = stitchedIndices
        let deps = DictationDependencies(
            recorder: recorder,
            engine: engine,
            cleaner: cleaner,
            deliverer: deliverer,
            history: history,
            planner: planner,
            stitch: stitch ?? { transcripts in
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

    /// Waits until `count` chunks have been transcribed (or given up on) in the background. It gives up after a
    /// while so that a broken session fails the test's expectations rather than hanging the run.
    func waitForChunks(done count: Int) async {
        for _ in 0..<20_000 {
            if await session.latestProgress.chunksDone >= count { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Waits until the engine has been given `count` calls.
    func waitForEngineCalls(_ count: Int) async {
        for _ in 0..<20_000 {
            if engine.calls.get().count >= count { return }
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
