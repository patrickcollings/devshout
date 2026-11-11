import Foundation

// Shared models used across modules. Owned by the integrator: add fields only when a feature needs them,
// keep everything Codable/Sendable, and keep this file free of Apple-only frameworks (it builds on Linux).

/// Audio inside devshout is always 16 kHz mono Float32 once it leaves the resampler.
public enum AudioFormat {
    public static let sampleRate: Int = 16_000
}

/// A dictation mode's identity: one of the three built-ins (`.raw`, `.tidy`, `.structure`) or a mode the user made
/// in Settings → Modes (`custom-<uuid>`). Raw never calls Claude.
///
/// It is a string wrapper rather than an enum so user-defined modes fit in the same type: everything that stores,
/// routes or compares a mode keeps working unchanged, and `.tidy` and friends read as before. What a custom mode
/// *is* (name, instructions, model, appearance) lives in `AppSettings.customModes`; look it up with
/// `AppSettings.descriptor(for:)` and `AppSettings.config(for:)`.
///
/// On disk it is the bare string, as it always was (`"tidy"`). A string that is neither a built-in name nor a
/// well-formed custom id doesn't decode, so the tolerant decoders fall back to their defaults for it.
public struct ModeID: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public static let raw = ModeID(unchecked: "raw")
    public static let tidy = ModeID(unchecked: "tidy")
    public static let structure = ModeID(unchecked: "structure")

    /// The built-in modes, in the order they are listed. They can't be deleted.
    public static let builtIns: [ModeID] = [.raw, .tidy, .structure]

    /// Every custom mode's id starts with this.
    public static let customPrefix = "custom-"

    /// Nil unless `rawValue` is a built-in name or `custom-` followed by letters, digits and hyphens (so the id is
    /// safe to use in a file, a UserDefaults key and a hotkey name).
    public init?(rawValue: String) {
        if Self.builtInNames[rawValue] == nil {
            guard rawValue.hasPrefix(Self.customPrefix) else { return nil }
            let rest = rawValue.dropFirst(Self.customPrefix.count)
            guard !rest.isEmpty, rest.count <= 64,
                  rest.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        }
        self.rawValue = rawValue
    }

    private init(unchecked rawValue: String) { self.rawValue = rawValue }

    /// A new id for a user-defined mode.
    public static func custom(_ uuid: UUID = UUID()) -> ModeID {
        ModeID(unchecked: customPrefix + uuid.uuidString.lowercased())
    }

    private static let builtInNames = ["raw": "Raw", "tidy": "Tidy", "structure": "Structure"]

    public var isBuiltIn: Bool { Self.builtInNames[rawValue] != nil }
    public var isCustom: Bool { !isBuiltIn }

    /// "Raw", "Tidy" or "Structure"; nil for a custom mode, whose name is in the settings.
    public var builtInName: String? { Self.builtInNames[rawValue] }

    /// The built-in name, or "Custom mode" where the settings aren't to hand (logs, the CLI). The UI shows a custom
    /// mode's own name through `AppSettings.descriptor(for:)`.
    public var displayName: String { builtInName ?? "Custom mode" }

    /// Every mode but Raw is cleaned up by Claude.
    public var usesClaude: Bool { self != .raw }
}

/// Per-mode settings for clean-up.
public struct ModeConfig: Codable, Sendable, Hashable {
    public var id: ModeID
    /// A Claude Code model alias ("haiku", "sonnet", "opus") or a full model name.
    public var claudeModel: String
    /// Seconds to wait for Claude before pasting the raw text instead.
    public var timeout: TimeInterval
    /// For a built-in mode: replaces the built-in instructions when set (Settings → Modes → Advanced).
    /// For a custom mode: the mode's instructions (see `PromptBuilder.systemPrompt`).
    public var customInstructions: String?

    public init(id: ModeID, claudeModel: String, timeout: TimeInterval, customInstructions: String? = nil) {
        self.id = id
        self.claudeModel = claudeModel
        self.timeout = timeout
        self.customInstructions = customInstructions
    }

    /// The longest `timeout` that is honoured, in seconds. Settings → Modes offers up to 120 s; this only bounds a
    /// hand-edited `settings.json`, where a huge number used to crash the app when it was turned into nanoseconds.
    public static let maximumTimeout: TimeInterval = 600

    /// `timeout` as it is used: 0 (no limit) for anything negative or not a number, and at most `maximumTimeout`.
    public var effectiveTimeout: TimeInterval {
        guard timeout > 0 else { return 0 }  // false for NaN too
        return min(timeout, Self.maximumTimeout)
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
