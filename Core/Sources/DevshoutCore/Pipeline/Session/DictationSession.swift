import Foundation

/// Drives one dictation (PLAN §3, §3.2): record → plan chunks → transcribe → stitch → glossary fixes → clean-up
/// (Tidy/Structure) → deliver → history. One instance per dictation.
///
/// Transcription runs while the recording goes on (PLAN §1 decision 4): the audio is passed to the chunk planner as
/// it arrives, and each chunk the planner cuts (at a pause, or at the engine's limit) is transcribed in the
/// background, one at a time and in order, because the engines run one call at a time. `stop()` gives the planner
/// the end of the audio, waits for the chunks still outstanding (normally just the tail) and carries on. So the wait
/// after stop is about one chunk's transcription, however long the dictation was, and the text is the same as
/// transcribing the whole recording after stop: the same chunks, in the same order, with the same context.
/// `progress` publishes the text so far, for the pill.
///
/// Audio is written to disk by the recorder before anything else sees it, and every outcome after recording starts
/// (finished, cancelled or failed) saves `record.json` next to the audio. Clean-up failures never fail the
/// dictation: the raw text is delivered and the reason recorded. `cancel()` abandons the background work at once:
/// no chunk is given to the engine after it, and one that is already there is not waited for.
///
/// One chunk failing doesn't lose the others: a chunk the engine can't transcribe is tried once more and then left
/// out, the rest is delivered, and the record's `errorMessage` says which part of the recording is missing. The
/// dictation only fails when no chunk gave any text.
///
/// Nothing the session waits for can hold it for ever: chunk planning and each chunk's transcription have a time
/// limit (`DictationOptions`), as clean-up always had. A chunk that runs out of time counts as failed. Nor can
/// planning or transcription hold up the recording: the recorder's stream is drained into a queue of its own.
///
/// States are published on `states`, which finishes after the terminal state (`finished`, `cancelled`, `failed`).
public actor DictationSession {
    public nonisolated let states: AsyncStream<SessionState>
    private let continuation: AsyncStream<SessionState>.Continuation
    /// How far transcription has got, each time a chunk is cut or finished. Only the latest value is kept for a
    /// reader that falls behind. Finishes with `states`.
    public nonisolated let progress: AsyncStream<TranscriptionProgress>
    private let progressContinuation: AsyncStream<TranscriptionProgress>.Continuation
    /// The value last published on `progress`.
    public private(set) var latestProgress = TranscriptionProgress()

    public private(set) var state: SessionState = .idle
    /// The mode the dictation will finish in. Can change while recording (`setMode`).
    public private(set) var mode: ModeID
    public private(set) var recordingID: UUID?
    public private(set) var audioURL: URL?

    private let deps: DictationDependencies
    private let settings: AppSettings
    private let options: DictationOptions

    private var record: Recording?
    /// Samples received from the recorder.
    private var sampleCount = 0
    private var collector: Task<Void, Never>?
    private var rawNowSignal: AsyncStream<Void>.Continuation?

    // Background planning and transcription (see `startBackgroundWork`).
    /// Audio on its way to the planner. Unbounded, so the recorder's stream is drained whatever the planner does.
    private var audioQueue: AsyncStream<[Float]>.Continuation?
    /// Chunks on their way to the engine.
    private var chunkQueue: AsyncStream<AudioChunk>.Continuation?
    private var planTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    /// The engine call in flight, so that `cancel()` can cancel it.
    private var engineCall: Task<ChunkTranscript, any Error>?
    /// Set by `cancel()` and by failures that end the dictation: nothing more is planned or transcribed.
    private var abandoned = false
    private enum Planning { case running, complete, failed(String) }
    private var planning: Planning = .running
    private var chunksPlanned = 0
    /// Chunks transcribed or given up on.
    private var chunksDone = 0
    /// Samples in the chunks planned but not done.
    private var pendingSamples = 0
    private var transcripts: [ChunkTranscript] = []
    private var skipped: [SkippedPart] = []
    private var engineStuck = false
    private var vocabularyPrompt: String?
    private var vocabularyPromptRead = false
    /// The stitched text of the chunks transcribed while recording (`TranscriptionProgress.text`).
    private var liveText = ""

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
        let (progress, progressContinuation) = AsyncStream<TranscriptionProgress>
            .makeStream(bufferingPolicy: .bufferingNewest(1))
        self.progress = progress
        self.progressContinuation = progressContinuation
    }

    deinit {
        continuation.finish()
        progressContinuation.finish()
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
        startBackgroundWork()
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
        sampleCount += buffer.count
        // Only queued here: the planner and the engine take it from there in their own time.
        audioQueue?.yield(buffer)
        guard phase == .recording else { return }
        publish(.recording(elapsed: Double(sampleCount) / Double(AudioFormat.sampleRate), level: Self.rms(buffer)))
    }

    // MARK: Planning and transcribing in the background

    /// Starts the two background tasks of a recording: one passes the audio to the planner and queues the chunks it
    /// cuts, the other transcribes the queued chunks one at a time. Both end by themselves once `stop()` has ended
    /// the audio (`drainCollector`) and the last chunk is done, or at `abandonBackgroundWork()`.
    private func startBackgroundWork() {
        let (audio, audioQueue) = AsyncStream<[Float]>.makeStream()
        let (chunks, chunkQueue) = AsyncStream<AudioChunk>.makeStream()
        self.audioQueue = audioQueue
        self.chunkQueue = chunkQueue
        let planner = deps.planner
        planTask = Task {
            do {
                for await buffer in audio {
                    // After a cancel the planner (and the detector behind it, which the next dictation will use)
                    // is left alone, whatever audio is still queued.
                    guard !self.abandoned else { return }
                    self.planned(try await planner.append(buffer))
                }
                guard !self.abandoned, !Task.isCancelled else { return }
                self.planned(try await planner.finish())
                self.planningEnded(failure: nil)
            } catch {
                self.planningEnded(failure: Self.describe(error))
            }
        }
        transcribeTask = Task {
            for await chunk in chunks {
                await self.transcribe(chunk)
            }
        }
    }

    private func planned(_ chunks: [AudioChunk]) {
        guard !abandoned, !chunks.isEmpty else { return }
        for chunk in chunks.sorted(by: { $0.index < $1.index }) {
            chunksPlanned += 1
            pendingSamples += chunk.samples.count
            chunkQueue?.yield(chunk)
        }
        publishProgress()
    }

    /// The planner has handed over the last chunk, or failed (`stop()` then fails the dictation).
    private func planningEnded(failure: String?) {
        guard !abandoned else { return }
        planning = failure.map { .failed($0) } ?? .complete
        audioQueue?.finish()
        audioQueue = nil
        chunkQueue?.finish()
        chunkQueue = nil
        publishProgress()
    }

    /// Transcribes one chunk and keeps the result. A chunk the engine can't do is tried once more, then left out.
    private func transcribe(_ chunk: AudioChunk) async {
        guard !abandoned else { return }
        let number = chunksDone + 1
        if engineStuck {
            skipped.append(SkippedPart(number: number, startSample: chunk.startSample, endSample: chunk.endSample,
                                       reason: "not tried, because the engine had stopped answering"))
            finished(chunk)
            return
        }
        let engine = deps.engine
        if !vocabularyPromptRead {
            vocabularyPromptRead = true
            vocabularyPrompt = engine.acceptsVocabularyPrompt ? deps.vocabularyPrompt() : nil
        }
        let context = TranscriptionContext(language: options.language, vocabularyPrompt: vocabularyPrompt,
                                           previousText: Self.tail(of: transcripts.last?.text,
                                                                   characters: options.previousTextCharacters))
        // One more try: a failure is often a one-off (the model being reloaded, a busy Neural Engine).
        var failure: String?
        var timeouts = 0
        let limit = options.chunkTimeout(forAudio: chunk.duration)
        for _ in 0..<2 {
            // The call has a task of its own so that cancel() can reach it. This task starts on the session, after
            // a cancel() that got in first, and then never calls the engine.
            let call = Task {
                try Task.checkCancellation()
                return try await engine.transcribe(chunk, context: context)
            }
            engineCall = call
            let outcome = await Self.bounded(limit) { try await call.value }
            // Cancelled meanwhile: whatever the engine said is dropped.
            guard !abandoned else { return }
            engineCall = nil
            switch outcome {
            case .value(let transcript):
                transcripts.append(transcript)
                failure = nil
            case .failed(let reason):
                failure = reason
            case .timedOut:
                // A stuck Core ML call can't be killed, only abandoned.
                call.cancel()
                failure = "the engine didn't answer within \(Self.seconds(limit))"
                timeouts += 1
            }
            if failure == nil { break }
        }
        // Out of time twice running: the engine is stuck, not slow. Both engines run one call at a time, so every
        // later chunk would queue behind the stuck call and run out of time as well, twice each. Give up on the
        // chunks still to come and deliver what there is, rather than sit in "transcribing" for minutes to learn
        // nothing.
        if timeouts == 2 { engineStuck = true }
        if let failure {
            skipped.append(SkippedPart(number: number, startSample: chunk.startSample, endSample: chunk.endSample,
                                       reason: failure))
        } else if phase == .recording {
            liveText = deps.stitch(transcripts)
        }
        finished(chunk)
    }

    private func finished(_ chunk: AudioChunk) {
        chunksDone += 1
        pendingSamples -= chunk.samples.count
        publishProgress()
    }

    private func publishProgress() {
        var complete = false
        if case .complete = planning { complete = true }
        latestProgress = TranscriptionProgress(
            text: liveText, chunksPlanned: chunksPlanned, chunksDone: chunksDone, planningComplete: complete,
            pendingAudio: Double(max(0, pendingSamples)) / Double(AudioFormat.sampleRate))
        progressContinuation.yield(latestProgress)
        // After stop, once the number of chunks is known, the state counts them down.
        if complete, phase == .finishing, case .transcribing = state {
            publish(.transcribing(done: chunksDone, total: chunksPlanned))
        }
    }

    /// Stops planning and transcribing for good. Nothing is given to the engine after this; a call already with the
    /// engine is cancelled and not waited for (a Core ML call can't be killed), and its result is dropped.
    private func abandonBackgroundWork() {
        abandoned = true
        audioQueue?.finish()
        audioQueue = nil
        chunkQueue?.finish()
        chunkQueue = nil
        planTask?.cancel()
        transcribeTask?.cancel()
        engineCall?.cancel()
        engineCall = nil
    }

    /// For tests: returns when the background tasks have ended.
    func backgroundWorkEnded() async {
        await planTask?.value
        await transcribeTask?.value
    }

    // MARK: Cancel

    /// Esc while recording: stops, keeps the audio and saves the record as cancelled. Chunks already transcribed in
    /// the background are dropped, and no more are transcribed. Called while the recorder is still starting, it
    /// waits for start-up and then cancels. `nil` when not recording.
    @discardableResult
    public func cancel() async -> DictationResult? {
        await waitForStartUp()
        guard phase == .recording, var rec = record else { return nil }
        phase = .finishing
        abandonBackgroundWork()
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

        // 1. Stop the recorder and collect the last buffers. That ends the audio for the planner, which then hands
        //    over the tail of the recording as the last chunk.
        var reportedDuration: TimeInterval?
        var recorderError: String?
        do {
            reportedDuration = try await deps.recorder.stop()
        } catch {
            recorderError = Self.describe(error)
        }
        await drainCollector()
        rec.duration = audioDuration(reported: reportedDuration)
        if let recorderError, sampleCount == 0 {
            abandonBackgroundWork()
            return fail(rec, stage: .recording, message: "Recording failed: \(recorderError)")
        }

        // 2. Wait for the planner to finish cutting. It has kept up with the recording, so this is the tail only.
        let planLimit = options.planningTimeout(forAudio: Double(sampleCount) / Double(AudioFormat.sampleRate))
        let planTask = planTask
        if case .timedOut = await Self.bounded(planLimit, { await planTask?.value }) {
            abandonBackgroundWork()
            keepTextSoFar(in: &rec)
            return fail(rec, stage: .transcribing,
                        message: "Couldn't split the audio: finding the speech in it took longer than "
                            + "\(Self.seconds(planLimit)), so devshout stopped waiting.")
        }
        if case .failed(let reason) = planning {
            abandonBackgroundWork()
            keepTextSoFar(in: &rec)
            return fail(rec, stage: .transcribing, message: "Couldn't split the audio: \(reason)")
        }
        let total = chunksPlanned
        guard total > 0 else {
            return fail(rec, stage: .transcribing, message: "No speech was detected.")
        }

        // 3. Wait for the chunks that aren't transcribed yet: the tail, and any the engine hadn't reached. Each has
        //    its own time limit, so this ends.
        await transcribeTask?.value
        let transcripts = transcripts.sorted { $0.index < $1.index }
        let partial = SkippedPart.summary(skipped, of: total)

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
                let what = total == 1 ? "the recording" : "any of the recording's \(total) parts"
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
        // The end of the audio: the planner is asked for the last chunk.
        audioQueue?.finish()
        audioQueue = nil
    }

    private func audioDuration(reported: TimeInterval?) -> TimeInterval {
        if let reported, reported > 0 { return reported }
        return Double(sampleCount) / Double(AudioFormat.sampleRate)
    }

    /// When the dictation fails after some chunks were transcribed, history still gets their text.
    private func keepTextSoFar(in rec: inout Recording) {
        guard !transcripts.isEmpty else { return }
        let text = deps.stitch(transcripts.sorted { $0.index < $1.index })
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { rec.rawText = text }
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
        progressContinuation.finish()
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
