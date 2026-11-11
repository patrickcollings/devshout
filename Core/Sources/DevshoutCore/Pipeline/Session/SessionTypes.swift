import Foundation

/// Where a dictation failed.
public enum SessionStage: String, Sendable, Hashable {
    case recording, transcribing, cleaning, delivering, saving
}

/// What a `DictationSession` is doing, published on `DictationSession.states` for the overlay and menu bar icon.
public enum SessionState: Sendable, Hashable {
    case idle
    /// `elapsed` is seconds of audio captured; `level` is the RMS (0...1) of the latest buffer.
    case recording(elapsed: TimeInterval, level: Float?)
    /// Recording has stopped and what is left is being transcribed: `done` of the recording's `total` chunks are
    /// finished, counting those transcribed while recording (`total` is 0 until the last chunk has been cut).
    case transcribing(done: Int, total: Int)
    /// Clean-up is running with this Claude model alias ("haiku", "sonnet", …).
    case cleaning(model: String)
    case delivering
    /// Delivered. `usedRaw`: Tidy/Structure fell back to the raw text, and `reason` says why.
    /// `authFailed`: Claude rejected the token, so the UI should offer Reconnect.
    case finished(outcome: DeliveryOutcome, usedRaw: Bool, reason: String?, authFailed: Bool)
    /// Esc while recording. The audio is kept in history.
    case cancelled
    /// Nothing was delivered. The audio and any text are saved in history.
    case failed(stage: SessionStage, message: String)

    public var isTerminal: Bool {
        switch self {
        case .finished, .cancelled, .failed: true
        default: false
        }
    }
}

/// How far transcription has got, published on `DictationSession.progress` each time it changes: chunks are
/// transcribed in the background while the recording goes on.
public struct TranscriptionProgress: Sendable, Hashable {
    /// The text of the chunks transcribed while recording, stitched: the engine's raw words, before glossary fixes
    /// and clean-up. A preview; it stops growing when recording stops.
    public var text: String
    /// Chunks cut from the recording so far. Final once `planningComplete`.
    public var chunksPlanned: Int
    /// Chunks finished: transcribed, or given up on.
    public var chunksDone: Int
    /// The recording has ended and its last chunk has been cut.
    public var planningComplete: Bool
    /// Seconds of audio in the chunks cut but not finished (including the one being transcribed).
    public var pendingAudio: TimeInterval

    public init(text: String = "", chunksPlanned: Int = 0, chunksDone: Int = 0, planningComplete: Bool = false,
                pendingAudio: TimeInterval = 0) {
        self.text = text
        self.chunksPlanned = chunksPlanned
        self.chunksDone = chunksDone
        self.planningComplete = planningComplete
        self.pendingAudio = pendingAudio
    }

    /// The last words of `text` that fit in `characters`, starting at a word boundary: one line for the pill.
    public func latestText(characters: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return DictationSession.tail(of: collapsed, characters: characters) ?? ""
    }
}

/// What `DictationSession.stop()` and `cancel()` return.
public struct DictationResult: Sendable {
    /// The record as saved (or as it would have been saved, when `saveError` is set).
    public var recording: Recording
    /// The final state: `.finished`, `.cancelled` or `.failed`.
    public var state: SessionState
    /// Why clean-up failed, when it did.
    public var cleanError: CleanError?
    /// Claude rejected the token: offer Reconnect (PLAN §0.1).
    public var authFailed: Bool
    /// Set when `record.json` couldn't be written.
    public var saveError: String?
    /// Set when the text was delivered without part of the recording, because the engine couldn't transcribe it:
    /// a short line for the pill ("Part 2 of 3 is missing: see History"). The full account, with where in the
    /// recording and why, is in `recording.errorMessage`.
    public var missingPartsNotice: String?

    public init(recording: Recording, state: SessionState, cleanError: CleanError? = nil, authFailed: Bool = false,
                saveError: String? = nil, missingPartsNotice: String? = nil) {
        self.recording = recording
        self.state = state
        self.cleanError = cleanError
        self.authFailed = authFailed
        self.saveError = saveError
        self.missingPartsNotice = missingPartsNotice
    }

    /// The text that reached the clipboard, if any.
    public var deliveredText: String? { recording.deliveredText }
}

/// Everything a `DictationSession` talks to. The app composes these; tests pass fakes.
public struct DictationDependencies: Sendable {
    public var recorder: any AudioRecorder
    public var engine: any TranscriptionEngine
    public var cleaner: any TextCleaner
    public var deliverer: any Deliverer
    public var history: HistoryStore
    /// Cuts this recording into chunks as it arrives (`VADChunkPlanner`). One per dictation.
    public var planner: any LiveChunkPlanner
    /// `Stitcher`: joins chunk transcripts (given in index order) into one text.
    public var stitch: @Sendable ([ChunkTranscript]) -> String
    /// `TextFixer`: the glossary's deterministic fixes.
    public var fixText: @Sendable (String) -> String
    /// The whole glossary as Claude should see it.
    public var glossaryForClaude: @Sendable () -> String
    /// `WhisperPromptBuilder`'s output, for engines that take a vocabulary prompt.
    public var vocabularyPrompt: @Sendable () -> String?
    public var dateSource: any DateSource

    public init(recorder: any AudioRecorder,
                engine: any TranscriptionEngine,
                cleaner: any TextCleaner,
                deliverer: any Deliverer,
                history: HistoryStore,
                planner: any LiveChunkPlanner,
                stitch: @escaping @Sendable ([ChunkTranscript]) -> String,
                fixText: @escaping @Sendable (String) -> String = { $0 },
                glossaryForClaude: @escaping @Sendable () -> String = { "" },
                vocabularyPrompt: @escaping @Sendable () -> String? = { nil },
                dateSource: any DateSource = SystemDateSource()) {
        self.recorder = recorder
        self.engine = engine
        self.cleaner = cleaner
        self.deliverer = deliverer
        self.history = history
        self.planner = planner
        self.stitch = stitch
        self.fixText = fixText
        self.glossaryForClaude = glossaryForClaude
        self.vocabularyPrompt = vocabularyPrompt
        self.dateSource = dateSource
    }
}

/// Tunables that aren't user settings.
public struct DictationOptions: Sendable, Hashable {
    /// Clean-up is abandoned (raw text pasted) after the mode's timeout plus this, even if the cleaner never returns.
    /// The cleaner enforces the timeout itself; this is a safety net.
    public var cleanGracePeriod: TimeInterval
    /// After `recorder.stop()`, how long to wait for the sample stream to finish before giving up on it.
    public var streamDrainTimeout: TimeInterval
    /// Characters of the previous chunk's text passed as `TranscriptionContext.previousText`.
    public var previousTextCharacters: Int
    /// Transcription language.
    public var language: String
    /// The time limit for transcribing one chunk is `chunkTimeoutPerAudioSecond` × the chunk's length, and at least
    /// `minimumChunkTimeout` seconds (see `chunkTimeout(forAudio:)`). A chunk that runs out of time is treated as
    /// failed: tried once more, then left out. Both 0 (or less) means no limit.
    ///
    /// The defaults, 30 s and 4×, are meant to be far from anything a working engine does, so that only a hang
    /// trips them: on the M1 Pro a 28 s Whisper chunk takes about 3 s and a 14.5 s Parakeet chunk well under 1 s,
    /// so 4× real time (112 s and 58 s for full chunks) is 40 to 100 times the normal case. That leaves room for a
    /// machine that is thermally throttled or busy, and the 30 s floor covers the fixed cost that doesn't shrink
    /// with the chunk (the first call after a model load). The price is that a real hang is only noticed after one
    /// to two minutes, twice (the retry); after that the rest of the chunks are not tried.
    public var minimumChunkTimeout: TimeInterval
    public var chunkTimeoutPerAudioSecond: Double
    /// The same for chunk planning (voice detection, which runs hundreds of times faster than real time and so
    /// keeps up with the recording): after stop, the planner gets `planningTimeoutPerAudioSecond` × the recording's
    /// length, at least `minimumPlanningTimeout` seconds, to hand over the last chunk. Taking longer than the
    /// recording itself is a hang; the dictation then fails, with the audio kept.
    public var minimumPlanningTimeout: TimeInterval
    public var planningTimeoutPerAudioSecond: Double

    public init(cleanGracePeriod: TimeInterval = 5, streamDrainTimeout: TimeInterval = 2,
                previousTextCharacters: Int = 200, language: String = "en",
                minimumChunkTimeout: TimeInterval = 30, chunkTimeoutPerAudioSecond: Double = 4,
                minimumPlanningTimeout: TimeInterval = 30, planningTimeoutPerAudioSecond: Double = 1) {
        self.cleanGracePeriod = cleanGracePeriod
        self.streamDrainTimeout = streamDrainTimeout
        self.previousTextCharacters = previousTextCharacters
        self.language = language
        self.minimumChunkTimeout = minimumChunkTimeout
        self.chunkTimeoutPerAudioSecond = chunkTimeoutPerAudioSecond
        self.minimumPlanningTimeout = minimumPlanningTimeout
        self.planningTimeoutPerAudioSecond = planningTimeoutPerAudioSecond
    }

    /// Seconds allowed for transcribing a chunk of `duration` seconds. 0 means no limit.
    public func chunkTimeout(forAudio duration: TimeInterval) -> TimeInterval {
        Self.limit(minimum: minimumChunkTimeout, perSecond: chunkTimeoutPerAudioSecond, duration: duration)
    }

    /// Seconds allowed for planning the chunks of a recording of `duration` seconds. 0 means no limit.
    public func planningTimeout(forAudio duration: TimeInterval) -> TimeInterval {
        Self.limit(minimum: minimumPlanningTimeout, perSecond: planningTimeoutPerAudioSecond, duration: duration)
    }

    private static func limit(minimum: TimeInterval, perSecond: Double, duration: TimeInterval) -> TimeInterval {
        let scaled = perSecond * max(0, duration)
        let limit = max(minimum, scaled)
        return limit > 0 ? limit : 0  // also 0 for NaN
    }
}

/// A chunk that was left out of a dictation because the engine couldn't transcribe it.
struct SkippedPart: Sendable, Hashable {
    /// 1-based position among the recording's chunks, as shown to the user.
    var number: Int
    var startSample: Int
    var endSample: Int
    var reason: String

    /// "0:14 to 0:29": where the part is in the recording, so it can be found again in the audio.
    var timeRange: String {
        "\(Self.clock(startSample)) to \(Self.clock(endSample))"
    }

    static func clock(_ sample: Int) -> String {
        let seconds = max(0, sample) / AudioFormat.sampleRate
        let minutes = seconds / 60
        let rest = seconds % 60
        return "\(minutes):\(rest < 10 ? "0" : "")\(rest)"
    }

    /// What to tell the user about the parts left out of a dictation of `total` parts: `detail` for the record's
    /// `errorMessage` (History), `notice` for the pill. Nil when nothing was left out.
    static func summary(_ skipped: [SkippedPart], of total: Int) -> (detail: String, notice: String)? {
        guard let first = skipped.first else { return nil }
        if skipped.count == 1 {
            return ("Part \(first.number) of \(total) (\(first.timeRange)) couldn't be transcribed and is missing "
                        + "from the text: \(first.reason). The audio was kept.",
                    "Part \(first.number) of \(total) is missing: see History")
        }
        let each = skipped.map { "part \($0.number) (\($0.timeRange)): \($0.reason)" }.joined(separator: "; ")
        return ("\(skipped.count) of \(total) parts couldn't be transcribed and are missing from the text: \(each). "
                    + "The audio was kept.",
                "\(skipped.count) of \(total) parts are missing: see History")
    }
}

/// How a clean-up failure is described in the overlay and history ("Pasted raw: …").
enum CleanFallback {
    static func reason(for error: CleanError) -> String {
        switch error {
        case .claudeNotFound: "Claude Code wasn't found"
        case .notConnected: "Claude isn't connected"
        case .authFailed: "Claude sign-in has expired or was revoked"
        case .timedOut(let after): "Claude timed out after \(Int(after.rounded())) s"
        case .processFailed(let exitCode, let message):
            message.isEmpty ? "Claude failed (exit code \(exitCode))" : "Claude failed: \(message)"
        case .rejectedOutput(let reason): "Claude's output was rejected: \(reason)"
        }
    }

    static func isAuthFailure(_ error: CleanError) -> Bool {
        if case .authFailed = error { return true }
        return false
    }

    static let rawRequested = "You chose to paste the raw text"
}
