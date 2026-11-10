import Foundation

// Shared models used across modules. Owned by the integrator: add fields only when a feature needs them,
// keep everything Codable/Sendable, and keep this file free of Apple-only frameworks (it builds on Linux).

/// Audio inside devshout is always 16 kHz mono Float32 once it leaves the resampler.
public enum AudioFormat {
    public static let sampleRate: Int = 16_000
}

/// The three dictation modes. Raw never calls Claude.
public enum ModeID: String, Codable, Sendable, CaseIterable, Hashable {
    case raw, tidy, structure

    public var displayName: String {
        switch self {
        case .raw: "Raw"
        case .tidy: "Tidy"
        case .structure: "Structure"
        }
    }

    public var usesClaude: Bool { self != .raw }
}

/// Per-mode settings for clean-up.
public struct ModeConfig: Codable, Sendable, Hashable {
    public var id: ModeID
    /// A Claude Code model alias ("haiku", "sonnet", "opus") or a full model name.
    public var claudeModel: String
    /// Seconds to wait for Claude before pasting the raw text instead.
    public var timeout: TimeInterval
    /// Replaces the built-in instructions for this mode when set (Settings → Modes → Advanced).
    public var customInstructions: String?

    public init(id: ModeID, claudeModel: String, timeout: TimeInterval, customInstructions: String? = nil) {
        self.id = id
        self.claudeModel = claudeModel
        self.timeout = timeout
        self.customInstructions = customInstructions
    }

    public static let defaults: [ModeID: ModeConfig] = [
        .raw: ModeConfig(id: .raw, claudeModel: "", timeout: 0),
        .tidy: ModeConfig(id: .tidy, claudeModel: "haiku", timeout: 20),
        .structure: ModeConfig(id: .structure, claudeModel: "sonnet", timeout: 45),
    ]
}

/// Transcription engines behind `TranscriptionEngine`.
public enum EngineID: String, Codable, Sendable, CaseIterable, Hashable {
    case parakeetV3 = "parakeet-tdt-0.6b-v3"
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"

    public var displayName: String {
        switch self {
        case .parakeetV3: "Parakeet TDT 0.6B v3"
        case .whisperLargeV3Turbo: "Whisper large-v3-turbo"
        }
    }
}

/// A slice of a recording handed to an engine. Sample positions are relative to the start of the recording.
public struct AudioChunk: Sendable, Hashable {
    public var index: Int
    public var startSample: Int
    public var endSample: Int
    /// Samples at the start of this chunk that repeat the end of the previous chunk (forced cuts only, else 0).
    public var overlapBefore: Int
    public var samples: [Float]

    public init(index: Int, startSample: Int, endSample: Int, overlapBefore: Int = 0, samples: [Float]) {
        self.index = index
        self.startSample = startSample
        self.endSample = endSample
        self.overlapBefore = overlapBefore
        self.samples = samples
    }

    public var duration: TimeInterval { Double(endSample - startSample) / Double(AudioFormat.sampleRate) }
}

/// A word (or token) with timings in seconds, relative to the start of the recording.
public struct TimedWord: Codable, Sendable, Hashable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// What an engine returns for one chunk.
public struct ChunkTranscript: Codable, Sendable, Hashable {
    public var index: Int
    public var startSample: Int
    public var endSample: Int
    public var overlapBefore: Int
    public var text: String
    /// Word timings relative to the start of the recording, when the engine provides them.
    public var words: [TimedWord]?
    public var engine: EngineID
    /// Wall-clock seconds the engine took.
    public var elapsed: TimeInterval

    public init(index: Int, startSample: Int, endSample: Int, overlapBefore: Int = 0, text: String,
                words: [TimedWord]? = nil, engine: EngineID, elapsed: TimeInterval) {
        self.index = index
        self.startSample = startSample
        self.endSample = endSample
        self.overlapBefore = overlapBefore
        self.text = text
        self.words = words
        self.engine = engine
        self.elapsed = elapsed
    }
}

/// Progress of a model download or load.
public struct ModelProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable { case downloading, compiling, loading, ready }
    public var phase: Phase
    /// 0...1 when known.
    public var fraction: Double?
    public var bytesDone: Int64?
    public var bytesTotal: Int64?

    public init(phase: Phase, fraction: Double? = nil, bytesDone: Int64? = nil, bytesTotal: Int64? = nil) {
        self.phase = phase
        self.fraction = fraction
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }
}

/// Extra input an engine may use.
public struct TranscriptionContext: Sendable, Hashable {
    public var language: String
    /// Comma-separated top glossary terms (Whisper only), built by `WhisperPromptBuilder`.
    public var vocabularyPrompt: String?
    /// Tail of the previous chunk's text, for Whisper conditioning.
    public var previousText: String?

    public init(language: String = "en", vocabularyPrompt: String? = nil, previousText: String? = nil) {
        self.language = language
        self.vocabularyPrompt = vocabularyPrompt
        self.previousText = previousText
    }
}

/// The Claude credential devshout keeps in the Keychain: a one-year token from `claude setup-token`.
public struct ClaudeCredential: Codable, Sendable, Hashable {
    public var token: String
    public var createdAt: Date

    public init(token: String, createdAt: Date) {
        self.token = token
        self.createdAt = createdAt
    }
}

/// The result of clean-up.
public struct CleanResult: Codable, Sendable, Hashable {
    public var text: String
    public var model: String
    public var elapsed: TimeInterval
    /// Non-fatal notes, e.g. "may have dropped: AB-1234".
    public var warnings: [String]

    public init(text: String, model: String, elapsed: TimeInterval, warnings: [String] = []) {
        self.text = text
        self.model = model
        self.elapsed = elapsed
        self.warnings = warnings
    }
}

/// Why clean-up failed. Every case means "paste the raw text instead".
public enum CleanError: Error, Sendable, Hashable {
    case claudeNotFound
    case notConnected
    /// Authentication failed: the token is missing, revoked or expired. The UI offers Reconnect.
    case authFailed(message: String)
    case timedOut(after: TimeInterval)
    case processFailed(exitCode: Int32, message: String)
    /// Output failed a sanity check (empty, answered the transcript instead of editing it, …).
    case rejectedOutput(reason: String)
}

/// How a finished dictation reached the user.
public enum DeliveryOutcome: Sendable, Hashable {
    /// ⌘V was sent to this app (display name), and the text is on the clipboard.
    case pasted(appName: String?)
    /// Only copied to the clipboard; `reason` says why no paste was sent.
    case copiedOnly(reason: String)
    /// Nothing reached the clipboard (no text, or the pasteboard refused it). The UI must not offer ⌘V.
    case failed(reason: String)
}
