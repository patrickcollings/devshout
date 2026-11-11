import Foundation

/// Drives one dictation (PLAN §3, §3.2): record → plan chunks → transcribe → stitch → glossary fixes → clean-up
/// (Tidy/Structure) → deliver → history. One instance per dictation.
///
/// v0.1 transcribes the whole recording after `stop()`. Audio is written to disk by the recorder before anything else
/// sees it, and every outcome after recording starts (finished, cancelled or failed) saves `record.json` next to the
/// audio. Clean-up failures never fail the dictation: the raw text is delivered and the reason recorded.
///
/// One chunk failing doesn't lose the others: a chunk the engine can't transcribe is tried once more and then left
/// out, the rest is delivered, and the record's `errorMessage` says which part of the recording is missing. The
/// dictation only fails when no chunk gave any text.
///
/// Nothing the session waits for can hold it for ever: chunk planning and each chunk's transcription have a time
/// limit (`DictationOptions`), as clean-up always had. A chunk that runs out of time counts as failed.
///
/// States are published on `states`, which finishes after the terminal state (`finished`, `cancelled`, `failed`).
public actor DictationSession {
    public nonisolated let states: AsyncStream<SessionState>
    private let continuation: AsyncStream<SessionState>.Continuation

    public private(set) var state: SessionState = .idle
    /// The mode the dictation will finish in. Can change while recording (`setMode`).
    public private(set) var mode: ModeID
    public private(set) var recordingID: UUID?
    public private(set) var audioURL: URL?

    private let deps: DictationDependencies
    private let settings: AppSettings
    private let options: DictationOptions

    private var record: Recording?
    private var samples: [Float] = []
    private var collector: Task<Void, Never>?
    private var rawNowSignal: AsyncStream<Void>.Continuation?

    private enum Phase { case idle, starting, recording, finishing, done }
    private var phase: Phase = .idle
    /// True from the recorder's start until its stream has drained, so buffers flushed at stop are kept.
    private var acceptingSamples = false
    /// `stop()`/`cancel()` calls that arrived while the recorder was still starting (e.g. a quick hold-to-talk
    /// release, or Esc while a Bluetooth microphone switches profile). They resume once start-up ends.
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    public init(dependencies: DictationDependencies, settings: AppSettings, options: DictationOptions = DictationOptions()) {
        self.deps = dependencies
        self.settings = settings
        self.options = options
        self.mode = settings.defaultMode
        let (stream, continuation) = AsyncStream<SessionState>.makeStream(bufferingPolicy: .bufferingNewest(512))
        self.states = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    // MARK: Recording

    /// Starts recording into a new history folder. Throws when the folder can't be made or the recorder won't
    /// start; the session is then `failed` and nothing is kept.
    @discardableResult
    public func start(mode: ModeID, targetApp: TargetApp?) async throws -> UUID {
        guard phase == .idle else { throw DictationSessionError.alreadyStarted }
        // Leave idle before the first suspension so a second start() is refused.
        phase = .starting
        self.mode = mode

        let folder: (id: UUID, audioURL: URL)
        do {
            folder = try deps.history.newRecordingFolder()
        } catch {
            phase = .done
            resumeStartWaiters()
            publishTerminal(.failed(stage: .recording, message: "Couldn't create the recording folder: \(Self.describe(error))"))
            throw error
        }
        recordingID = folder.id
        audioURL = folder.audioURL
        record = Recording(id: folder.id, createdAt: deps.dateSource.now(), status: .completed, mode: mode,
                           modeName: settings.storedName(for: mode), targetApp: targetApp, engine: deps.engine.id)

        let stream: AsyncStream<[Float]>
        do {
            stream = try await deps.recorder.start(writingTo: folder.audioURL)
        } catch {
            // No audio was captured, so there is nothing worth keeping.
            try? deps.history.delete(folder.id)
            phase = .done
            resumeStartWaiters()
            publishTerminal(.failed(stage: .recording, message: "Couldn't start recording: \(Self.describe(error))"))
            throw error
        }
        phase = .recording
        acceptingSamples = true
        publish(.recording(elapsed: 0, level: nil))
        collector = Task { [stream] in
            for await buffer in stream {
                self.append(buffer)
            }
        }
        resumeStartWaiters()
        return folder.id
    }

    /// Switches the mode while recording (another mode's hotkey). Returns `false` once clean-up has begun.
    @discardableResult
    public func setMode(_ newMode: ModeID) -> Bool {
        // Clean-up reads the mode once transcription ends; until then a switch takes effect.
        let canSwitch: Bool
        switch state {
        case .idle, .recording, .transcribing: canSwitch = phase != .done
        default: canSwitch = false
        }
        guard canSwitch else { return false }
        mode = newMode
        record?.mode = newMode
        record?.modeName = settings.storedName(for: newMode)
        return true
    }

    /// During clean-up: stop waiting for Claude and deliver the raw text ("Paste raw now ⏎").
    public func pasteRawNow() {
        rawNowSignal?.yield()
    }

    private func append(_ buffer: [Float]) {
        guard acceptingSamples else { return }
        samples.append(contentsOf: buffer)
        guard phase == .recording else { return }
        publish(.recording(elapsed: Double(samples.count) / Double(AudioFormat.sampleRate), level: Self.rms(buffer)))
    }

    // MARK: Cancel

    /// Esc while recording: stops, keeps the audio and saves the record as cancelled. Called while the recorder is
    /// still starting, it waits for start-up and then cancels. `nil` when not recording.
    @discardableResult
    public func cancel() async -> DictationResult? {
        await waitForStartUp()
        guard phase == .recording, var rec = record else { return nil }
        phase = .finishing
        await deps.recorder.cancel()
        await drainCollector()
        rec.status = .cancelled
        rec.duration = audioDuration(reported: nil)
        return saveAndFinish(rec, state: .cancelled)
    }

    // MARK: Stop

    /// Stops recording and runs the rest of the pipeline. Never throws: failures end in `.failed` (with the record
    /// saved), and clean-up failures deliver the raw text. Called while the recorder is still starting, it waits for
    /// start-up and then stops. `nil` when not recording.
    @discardableResult
    public func stop() async -> DictationResult? {
        await waitForStartUp()
        guard phase == .recording, var rec = record else { return nil }
        phase = .finishing
        publish(.transcribing(done: 0, total: 0))
        let stoppedAt = deps.dateSource.now()

        // 1. Stop the recorder and collect the last buffers.
        var reportedDuration: TimeInterval?
        var recorderError: String?
        do {
            reportedDuration = try await deps.recorder.stop()
        } catch {
            recorderError = Self.describe(error)
        }
        await drainCollector()
        rec.duration = audioDuration(reported: reportedDuration)
        if let recorderError, samples.isEmpty {
            return fail(rec, stage: .recording, message: "Recording failed: \(recorderError)")
        }

        // 2. Plan chunks.
        let chunks: [AudioChunk]
        let planChunks = deps.planChunks
        let recorded = samples
        let planLimit = options.planningTimeout(forAudio: Double(recorded.count) / Double(AudioFormat.sampleRate))
        switch await Self.bounded(planLimit, { try await planChunks(recorded) }) {
        case .value(let planned):
            chunks = planned.sorted { $0.index < $1.index }
        case .failed(let reason):
            return fail(rec, stage: .transcribing, message: "Couldn't split the audio: \(reason)")
        case .timedOut:
            return fail(rec, stage: .transcribing,
                        message: "Couldn't split the audio: finding the speech in it took longer than "
                            + "\(Self.seconds(planLimit)), so devshout stopped waiting.")
        }
        guard !chunks.isEmpty else {
            return fail(rec, stage: .transcribing, message: "No speech was detected.")
        }

        // 3. Transcribe each chunk in order.
        let engine = deps.engine
        let vocabulary = engine.acceptsVocabularyPrompt ? deps.vocabularyPrompt() : nil
        var transcripts: [ChunkTranscript] = []
        var skipped: [SkippedPart] = []
        var engineStuck = false
        for (position, chunk) in chunks.enumerated() {
            publish(.transcribing(done: position, total: chunks.count))
            if engineStuck {
                skipped.append(SkippedPart(number: position + 1, startSample: chunk.startSample,
                                           endSample: chunk.endSample,
                                           reason: "not tried, because the engine had stopped answering"))
                continue
            }
            let context = TranscriptionContext(language: options.language, vocabularyPrompt: vocabulary,
                                               previousText: Self.tail(of: transcripts.last?.text,
                                                                       characters: options.previousTextCharacters))
            // One more try: a failure is often a one-off (the model being reloaded, a busy Neural Engine).
            var failure: String?
            var timeouts = 0
            let limit = options.chunkTimeout(forAudio: chunk.duration)
            for _ in 0..<2 {
                switch await Self.bounded(limit, { try await engine.transcribe(chunk, context: context) }) {
                case .value(let transcript):
                    transcripts.append(transcript)
                    failure = nil
                case .failed(let reason):
                    failure = reason
                case .timedOut:
                    failure = "the engine didn't answer within \(Self.seconds(limit))"
                    timeouts += 1
                }
                if failure == nil { break }
            }
            // Out of time twice running: the engine is stuck, not slow. Both engines run one call at a time, so
            // every later chunk would queue behind the stuck call and run out of time as well, twice each. Stop
            // here and deliver what there is, rather than sit in "transcribing" for minutes to learn nothing.
            if timeouts == 2 { engineStuck = true }
            if let failure {
                skipped.append(SkippedPart(number: position + 1, startSample: chunk.startSample,
                                           endSample: chunk.endSample, reason: failure))
            }
        }
        publish(.transcribing(done: chunks.count, total: chunks.count))
        let partial = SkippedPart.summary(skipped, of: chunks.count)

        // 4. Stitch and apply glossary fixes.
        let raw = deps.stitch(transcripts)
        if !transcripts.isEmpty { rec.rawText = raw }
        var text = raw
        if settings.applyGlossaryFixes, !transcripts.isEmpty {
            text = deps.fixText(raw)
            rec.fixedText = text
            rec.fixesApplied = true
        }
        rec.timings.transcription = deps.dateSource.now().timeIntervalSince(stoppedAt)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Nothing to deliver. Say why when the engine failed, rather than blaming the speaker.
            if let first = skipped.first {
                let what = chunks.count == 1 ? "the recording" : "any of the recording's \(chunks.count) parts"
                return fail(rec, stage: .transcribing, message: "Couldn't transcribe \(what): \(first.reason)")
            }
            return fail(rec, stage: .transcribing, message: "No speech was detected.")
        }

        // 5. Clean-up (Tidy, Structure). Any failure delivers the raw text.
        let finalMode = mode
        rec.mode = finalMode
        rec.modeName = settings.storedName(for: finalMode)
        var deliveredText = text
        var usedRaw = false
        var reason: String?
        var cleanError: CleanError?
        if finalMode.usesClaude {
            let config = settings.config(for: finalMode)
            publish(.cleaning(model: config.claudeModel))
            let cleanStart = deps.dateSource.now()
            let attempt = await runCleaner(text, config: config)
            rec.timings.cleaning = deps.dateSource.now().timeIntervalSince(cleanStart)
            switch attempt {
            case .cleaned(let result):
                deliveredText = result.text
                rec.versions.append(CleanVersion(result, mode: finalMode, modeName: rec.modeName,
                                                 createdAt: deps.dateSource.now()))
            case .failed(let error):
                usedRaw = true
                cleanError = error
                reason = CleanFallback.reason(for: error)
            case .rawRequested:
                usedRaw = true
                reason = CleanFallback.rawRequested
            }
        }
        rec.fallbackReason = reason
        let authFailed = cleanError.map(CleanFallback.isAuthFailure) ?? false

        // 6. Deliver.
        publish(.delivering)
        let deliverStart = deps.dateSource.now()
        let outcome = await deps.deliverer.deliver(deliveredText)
        let deliveredAt = deps.dateSource.now()
        rec.timings.delivery = deliveredAt.timeIntervalSince(deliverStart)
        rec.timings.total = deliveredAt.timeIntervalSince(stoppedAt)
        rec.deliveredText = deliveredText
        rec.delivered = DeliveryRecord(outcome)
        rec.status = .completed
        // Problems that didn't stop the dictation, for History.
        let problems = [partial?.detail, recorderError.map { "The recorder reported: \($0)" }].compactMap { $0 }
        if !problems.isEmpty { rec.errorMessage = problems.joined(separator: " ") }

        // 7. History.
        let finished = SessionState.finished(outcome: outcome, usedRaw: usedRaw, reason: reason, authFailed: authFailed)
        var result = saveAndFinish(rec, state: finished)
        result.cleanError = cleanError
        result.authFailed = authFailed
        result.missingPartsNotice = partial?.notice
        return result
    }

    // MARK: Clean-up

    private enum CleanAttempt: Sendable {
        case cleaned(CleanResult)
        case failed(CleanError)
        case rawRequested
    }

    /// Races the cleaner against "Paste raw now" and a safety-net timeout.
    private func runCleaner(_ text: String, config: ModeConfig) async -> CleanAttempt {
        let cleaner = deps.cleaner
        let glossary = deps.glossaryForClaude()
        let (signal, signalContinuation) = AsyncStream<Void>.makeStream()
        rawNowSignal = signalContinuation
        defer {
            rawNowSignal = nil
            signalContinuation.finish()
        }

        var racers: [@Sendable () async -> CleanAttempt] = [
            {
                do {
                    let result = try await cleaner.clean(text, mode: config, glossary: glossary)
                    if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return .failed(.rejectedOutput(reason: "empty output"))
                    }
                    return .cleaned(result)
                } catch let error as CleanError {
                    return .failed(error)
                } catch {
                    return .failed(.processFailed(exitCode: -1, message: Self.describe(error)))
                }
            },
            {
                for await _ in signal { return .rawRequested }
                // Finished without a request: only happens once another racer has won.
                return .rawRequested
            },
        ]
        if config.timeout > 0 {
            let limit = config.timeout + max(0, options.cleanGracePeriod)
            let timeout = config.timeout
            racers.append {
                try? await Task.sleep(nanoseconds: sleepNanoseconds(limit))
                return .failed(.timedOut(after: timeout))
            }
        }
        return await firstToFinish(racers)
    }

    // MARK: Time limits

    private enum Bounded<Value: Sendable>: Sendable {
        case value(Value)
        case failed(String)
        case timedOut
    }

    /// Runs `operation`, but stops waiting after `limit` seconds (0 or less: no limit). The operation is cancelled
    /// then, and whatever it does afterwards is ignored; a stuck Core ML call can't be killed, only abandoned.
    private nonisolated static func bounded<Value: Sendable>(
        _ limit: TimeInterval, _ operation: @escaping @Sendable () async throws -> Value
    ) async -> Bounded<Value> {
        var racers: [@Sendable () async -> Bounded<Value>] = [
            {
                do {
                    return .value(try await operation())
                } catch {
                    return .failed(describe(error))
                }
            },
        ]
        if limit > 0 {
            racers.append {
                try? await Task.sleep(nanoseconds: sleepNanoseconds(limit))
                return .timedOut
            }
        }
        return await firstToFinish(racers)
    }

    /// "30 s", "2.5 s".
    nonisolated static func seconds(_ limit: TimeInterval) -> String {
        let rounded = (min(max(limit, 0), 86_400) * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded)) s" : "\(rounded) s"
    }

    // MARK: Helpers

    /// While the recorder is starting, waits until it has started (or failed to).
    private func waitForStartUp() async {
        guard phase == .starting else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startWaiters.append(continuation)
        }
    }

    private func resumeStartWaiters() {
        let waiters = startWaiters
        startWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Waits for the sample stream to end after the recorder stopped (bounded, in case a recorder never finishes it).
    private func drainCollector() async {
        guard let collector else { return }
        let nanos = sleepNanoseconds(options.streamDrainTimeout)
        let racers: [@Sendable () async -> Bool] = [
            { await collector.value; return true },
            { try? await Task.sleep(nanoseconds: nanos); return false },
        ]
        let drained = await firstToFinish(racers)
        if !drained {
            collector.cancel()
            await collector.value
        }
        acceptingSamples = false
        self.collector = nil
    }

    private func audioDuration(reported: TimeInterval?) -> TimeInterval {
        if let reported, reported > 0 { return reported }
        return Double(samples.count) / Double(AudioFormat.sampleRate)
    }

    private func fail(_ rec: Recording, stage: SessionStage, message: String) -> DictationResult {
        var rec = rec
        rec.status = .failed
        rec.errorMessage = message
        return saveAndFinish(rec, state: .failed(stage: stage, message: message))
    }

    private func saveAndFinish(_ rec: Recording, state terminal: SessionState) -> DictationResult {
        record = rec
        var saveError: String?
        do {
            try deps.history.save(rec)
        } catch {
            saveError = Self.describe(error)
        }
        publishTerminal(terminal)
        return DictationResult(recording: rec, state: terminal, saveError: saveError)
    }

    private func publish(_ newState: SessionState) {
        state = newState
        continuation.yield(newState)
    }

    private func publishTerminal(_ newState: SessionState) {
        phase = .done
        publish(newState)
        continuation.finish()
    }

    static func rms(_ buffer: [Float]) -> Float? {
        guard !buffer.isEmpty else { return nil }
        var sum: Float = 0
        for sample in buffer { sum += sample * sample }
        return min(1, (sum / Float(buffer.count)).squareRoot())
    }

    /// The last `characters` of `text`, starting at a word boundary.
    static func tail(of text: String?, characters: Int) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, characters > 0 else {
            return nil
        }
        guard text.count > characters else { return text }
        let cut = String(text.suffix(characters))
        if let space = cut.firstIndex(where: \.isWhitespace) {
            let trimmed = cut[space...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return cut
    }

    nonisolated static func describe(_ error: any Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return String(describing: error)
    }
}

public enum DictationSessionError: Error, Sendable, Hashable {
    /// `start` was called on a session that already started. Make a new session per dictation.
    case alreadyStarted
}

/// Seconds as nanoseconds for `Task.sleep`, for any `Double`: 0 for a negative number or NaN, and capped at a day
/// (`UInt64(seconds * 1e9)` traps on a number that doesn't fit, which a hand-edited timeout can be).
func sleepNanoseconds(_ seconds: TimeInterval) -> UInt64 {
    guard seconds > 0 else { return 0 }  // false for NaN too
    return UInt64(min(seconds, 86_400) * 1_000_000_000)
}

/// Runs the operations at once and returns the first result; the others are cancelled (and not awaited, so an
/// operation that ignores cancellation can't hold up the caller).
func firstToFinish<T: Sendable>(_ operations: [@Sendable () async -> T]) async -> T {
    precondition(!operations.isEmpty)
    let race = Race<T>()
    return await withCheckedContinuation { continuation in
        race.set(continuation)
        for operation in operations {
            race.add(Task { race.resolve(await operation()) })
        }
    }
}

private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var done = false

    func set(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func add(_ task: Task<Void, Never>) {
        lock.lock()
        if done {
            lock.unlock()
            task.cancel()
            return
        }
        tasks.append(task)
        lock.unlock()
    }

    func resolve(_ value: T) {
        lock.lock()
        guard !done, let continuation else {
            lock.unlock()
            return
        }
        done = true
        self.continuation = nil
        let losers = tasks
        tasks = []
        lock.unlock()
        continuation.resume(returning: value)
        losers.forEach { $0.cancel() }
    }
}
