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
    /// `done` of `total` chunks transcribed (`total` is 0 while chunks are still being planned).
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
    /// VAD + `ChunkPlanner` over the whole recording (v0.1 transcribes after stop).
    public var planChunks: @Sendable ([Float]) async throws -> [AudioChunk]
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
                planChunks: @escaping @Sendable ([Float]) async throws -> [AudioChunk],
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
        self.planChunks = planChunks
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

    public init(cleanGracePeriod: TimeInterval = 5, streamDrainTimeout: TimeInterval = 2,
                previousTextCharacters: Int = 200, language: String = "en") {
        self.cleanGracePeriod = cleanGracePeriod
        self.streamDrainTimeout = streamDrainTimeout
        self.previousTextCharacters = previousTextCharacters
        self.language = language
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
