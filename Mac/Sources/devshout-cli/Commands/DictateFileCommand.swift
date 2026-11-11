// devshout-cli dictate-file: one file through the app's own DictationSession, as if it were being dictated.
//
// The other commands use Core's SpikeTranscriber; this one runs what the app runs after a hotkey press: a recorder
// (here one that plays a file at the pace of a microphone, writing the WAV first), the Silero-backed chunk planner,
// the real engine, the Stitcher, and a deliverer (here one that prints). It measures the wait between stop and the
// text, which is what transcribing while recording is for, and can run the same file transcribed after stop to
// compare. Raw mode only: Claude is never called, and the history record goes to a temporary folder.
import ArgumentParser
import DevshoutCore
import DevshoutMac
import Foundation

struct DictateFileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dictate-file",
        abstract: "Run a recording through the app's dictation session and time the wait after stop.",
        discussion: """
        Plays the file into the session the app uses for a dictation (Raw mode), stops when the file ends, and \
        reports how long the text took after the stop. With --realtime the audio arrives at the pace of a \
        microphone, so chunks are transcribed while it is still playing, as in the app; without it the whole file \
        arrives at once and everything is transcribed after the stop. --after-stop holds every chunk back until \
        the stop, which is how devshout worked before it transcribed while recording. --compare runs both ways \
        and checks that the text is the same. The text goes to stdout; progress and timings go to stderr.
        """
    )

    @Argument(help: "A WAV file (any sample rate; other formats macOS can read also work).")
    var input: String

    @Option(help: "parakeet or whisper.")
    var engine: EngineChoice

    @Flag(help: "Play the file at the pace of a microphone (takes as long as the recording).")
    var realtime = false

    @Flag(name: .customLong("after-stop"), help: "Transcribe only after the stop (the old behaviour), for comparison.")
    var afterStop = false

    @Flag(help: "Run the file both ways, live and after stop, and compare the wait and the text.")
    var compare = false

    func validate() throws {
        if compare, afterStop { throw ValidationError("--compare already includes the --after-stop run.") }
    }

    mutating func run() async throws {
        let url = try Files.existing(input, what: "audio file")
        let samples = try readAudio(url)
        let duration = Double(samples.count) / Double(AudioFormat.sampleRate)
        Console.error("Read \(url.lastPathComponent): \(SpikeFormat.clock(duration)) of audio.")

        let host = EngineHost()
        _ = try await host.prepare(engine.id)
        _ = try await host.prepareVAD()
        let speechEngine = await host.engine(engine.id)

        // The first call after a load is slower than the rest; the app's engine has usually been used before.
        let warmUp = AudioChunk(index: 0, startSample: 0, endSample: min(samples.count, 2 * AudioFormat.sampleRate),
                                samples: Array(samples.prefix(2 * AudioFormat.sampleRate)))
        _ = try? await speechEngine.transcribe(warmUp, context: TranscriptionContext())

        var runs: [DictateFileRun] = []
        for deferring in compare ? [false, true] : [afterStop] {
            let run = try await DictateFileRun.make(samples: samples, engine: speechEngine, vad: host.vad,
                                                    realtime: realtime, afterStop: deferring)
            runs.append(run)
            Console.error("")
            for line in run.lines { Console.error(line) }
        }
        await host.unloadAll()

        Console.out(runs[0].text)
        if compare, runs.count == 2 {
            Console.error("")
            Console.error(String(format: "Wait after stop: %.2f s live, %.2f s after stop.",
                                 runs[0].stopToText, runs[1].stopToText))
            Console.error(runs[0].text == runs[1].text
                          ? "The text is the same both ways."
                          : "The text DIFFERS. After stop: \(runs[1].text)")
            if runs[0].text != runs[1].text { throw ExitCode.failure }
        }
    }
}

/// One dictation of the file, and what it measured.
struct DictateFileRun {
    var afterStop: Bool
    var realtime: Bool
    var text: String
    var audioDuration: TimeInterval
    var chunks: Int
    /// Chunks transcribed when the stop came.
    var chunksBeforeStop: Int
    /// From calling `stop()` to the deliverer being given the text.
    var stopToText: TimeInterval
    /// Process CPU time (user + system) used from the start of the recording to the text.
    var cpuSeconds: TimeInterval
    /// The same, up to the stop only.
    var cpuWhileRecording: TimeInterval
    /// The longest the session took to take a buffer from the recorder's stream.
    var worstBufferLag: TimeInterval
    /// The latest a buffer was sent, against the pace of a microphone.
    var worstSendDelay: TimeInterval
    var problem: String?
    var events: [String]

    var lines: [String] {
        var lines = ["\(afterStop ? "Transcribed after stop" : "Transcribed while recording")"
            + (realtime ? " (audio at microphone pace)" : " (audio all at once)") + ":"]
        lines += events.map { "  \($0)" }
        lines.append("  Chunks: \(chunks), of which \(chunksBeforeStop) were done when the recording stopped")
        lines.append(String(format: "  Wait after stop (stop → text): %.2f s", stopToText))
        lines.append(String(format: "  CPU time: %.2f s in all, %.2f s of it while recording (%.0f%% of one core)",
                            cpuSeconds, cpuWhileRecording,
                            audioDuration > 0 && realtime ? cpuWhileRecording / audioDuration * 100 : 0))
        if realtime {
            lines.append(String(format: "  Audio buffers: sent at most %.0f ms late, taken by the session within %.0f ms",
                                worstSendDelay * 1000, worstBufferLag * 1000))
        }
        if let problem { lines.append("  Problem: \(problem)") }
        return lines
    }

    static func make(samples: [Float], engine: any TranscriptionEngine, vad: SileroVAD, realtime: Bool,
                     afterStop: Bool) async throws -> DictateFileRun {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devshout-dictate-file-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = FilePlayingRecorder(samples: samples, realtime: realtime)
        let deliverer = PrintingDeliverer()
        let dependencies = DictationDependencies(
            recorder: recorder,
            engine: engine,
            cleaner: NoCleaner(),
            deliverer: deliverer,
            history: HistoryStore(root: root),
            planner: vad.chunkPlanner(maxChunkDuration: engine.maxChunkDuration, defersUntilFinish: afterStop),
            stitch: { Stitcher.stitch($0) })
        var settings = AppSettings()
        settings.applyGlossaryFixes = false
        let session = DictationSession(dependencies: dependencies, settings: settings)

        // What the pill would follow: the session's states (how promptly audio is taken) and its progress.
        let watchingStates = Task {
            var worst: TimeInterval = 0
            for await state in session.states {
                if case .recording(let elapsed, _) = state, elapsed > 0 {
                    worst = max(worst, recorder.lag(atSample: Int((elapsed * Double(AudioFormat.sampleRate)).rounded())))
                }
            }
            return worst
        }
        let started = SpikeClock.now()
        let watchingProgress = Task {
            var events: [String] = []
            var done = 0
            for await progress in session.progress where progress.chunksDone > done {
                done = progress.chunksDone
                let preview = progress.latestText(characters: 48)
                events.append(String(format: "%6.2f s  chunk %d done", SpikeClock.now() - started, done)
                              + (preview.isEmpty ? "" : "  …\(preview)"))
            }
            return events
        }

        let cpuAtStart = processCPUSeconds()
        try await session.start(mode: .raw, targetApp: nil)
        await recorder.playedToEnd()
        let chunksBeforeStop = await session.latestProgress.chunksDone
        let cpuAtStop = processCPUSeconds()
        let stopAt = SpikeClock.now()
        let result = await session.stop()
        let cpuAtEnd = processCPUSeconds()
        let worstLag = await watchingStates.value
        var events = await watchingProgress.value
        events.append(String(format: "%6.2f s  recording stopped", stopAt - started))

        var problem: String?
        if case .failed(_, let message)? = result?.state { problem = message }
        if let missing = result?.recording.errorMessage, problem == nil { problem = missing }
        let deliveredAt = deliverer.deliveredAt ?? SpikeClock.now()
        return DictateFileRun(afterStop: afterStop, realtime: realtime, text: deliverer.text ?? "",
                              audioDuration: Double(samples.count) / Double(AudioFormat.sampleRate),
                              chunks: await session.latestProgress.chunksPlanned, chunksBeforeStop: chunksBeforeStop,
                              stopToText: deliveredAt - stopAt, cpuSeconds: cpuAtEnd - cpuAtStart,
                              cpuWhileRecording: cpuAtStop - cpuAtStart, worstBufferLag: worstLag,
                              worstSendDelay: recorder.worstSendDelay, problem: problem, events: events)
    }
}

/// User plus system CPU time of this process so far.
private func processCPUSeconds() -> TimeInterval {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> TimeInterval { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// Stands in for the microphone: sends a file's samples in buffers the size the microphone gives (about 85 ms),
/// each written to the WAV before it is sent, as `MicRecorder` does. With `realtime` the buffers go out on their
/// own thread at the pace of the recording; otherwise all at once.
final class FilePlayingRecorder: AudioRecorder, @unchecked Sendable {
    private static let bufferSize = 1_365

    private let samples: [Float]
    private let realtime: Bool
    private let lock = NSLock()
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var writer: WavFileWriter?
    private var stopRequested = false
    private var finished = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    /// When each buffer was sent, by the sample count it brought the recording to.
    private var sent: [(samples: Int, at: TimeInterval)] = []
    private var _worstSendDelay: TimeInterval = 0

    init(samples: [Float], realtime: Bool) {
        self.samples = samples
        self.realtime = realtime
    }

    var worstSendDelay: TimeInterval { lock.withLock { _worstSendDelay } }

    /// How long ago the buffer that brought the recording to `sample` samples was sent.
    func lag(atSample sample: Int) -> TimeInterval {
        let now = SpikeClock.now()
        return lock.withLock {
            guard let entry = sent.first(where: { $0.samples >= sample }) else { return 0 }
            return max(0, now - entry.at)
        }
    }

    func start(writingTo fileURL: URL) async throws -> AsyncStream<[Float]> {
        let writer = try WavFileWriter(url: fileURL)
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        lock.withLock {
            self.writer = writer
            self.continuation = continuation
        }
        let thread = Thread { [self] in play() }
        thread.qualityOfService = .userInitiated
        thread.start()
        return stream
    }

    private func play() {
        let rate = Double(AudioFormat.sampleRate)
        let start = SpikeClock.now()
        var position = 0
        while position < samples.count {
            if lock.withLock({ stopRequested }) { break }
            let end = min(position + Self.bufferSize, samples.count)
            if realtime {
                // A buffer exists once its last sample has been spoken.
                let due = start + Double(end) / rate
                let wait = due - SpikeClock.now()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                let late = SpikeClock.now() - due
                lock.withLock { _worstSendDelay = max(_worstSendDelay, late) }
            }
            let buffer = Array(samples[position..<end])
            // Disk first, then the stream.
            try? lock.withLock({ writer })?.write(buffer)
            lock.withLock { sent.append((end, SpikeClock.now())) }
            lock.withLock({ continuation })?.yield(buffer)
            position = end
        }
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            finished = true
            defer { finishWaiters = [] }
            return finishWaiters
        }
        waiters.forEach { $0.resume() }
    }

    /// Returns when the whole file has been sent (the moment the user would press stop).
    func playedToEnd() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let done = lock.withLock { () -> Bool in
                if !finished { finishWaiters.append(waiter) }
                return finished
            }
            if done { waiter.resume() }
        }
    }

    func stop() async throws -> TimeInterval {
        lock.withLock { stopRequested = true }
        await playedToEnd()
        let (writer, continuation) = lock.withLock { (self.writer, self.continuation) }
        let duration = (try? writer?.close()) ?? 0
        continuation?.finish()
        return duration
    }

    func cancel() async {
        _ = try? await stop()
    }
}

/// Keeps the text it is given and when, instead of pasting it.
final class PrintingDeliverer: Deliverer, @unchecked Sendable {
    private let lock = NSLock()
    private var _text: String?
    private var _deliveredAt: TimeInterval?

    var text: String? { lock.withLock { _text } }
    var deliveredAt: TimeInterval? { lock.withLock { _deliveredAt } }

    func deliver(_ text: String) async -> DeliveryOutcome {
        lock.withLock {
            _text = text
            _deliveredAt = SpikeClock.now()
        }
        return .copiedOnly(reason: "devshout-cli dictate-file")
    }
}

/// Raw mode never cleans up, so this is never called.
struct NoCleaner: TextCleaner {
    func clean(_ raw: String, mode: ModeConfig, glossary: String) async throws -> CleanResult {
        throw CleanError.notConnected
    }
}
