import Foundation

// Seams between modules. Core code depends only on these; macOS implementations live in Mac/Sources/DevshoutMac,
// and tests use fakes. Owned by the integrator: change a signature only together with every implementer.

/// A speech-to-text engine (Parakeet via FluidAudio, Whisper via WhisperKit).
public protocol TranscriptionEngine: AnyObject, Sendable {
    var id: EngineID { get }
    /// The longest chunk the engine accepts, in seconds (Parakeet ≈ 14.5, Whisper ≈ 28).
    var maxChunkDuration: TimeInterval { get }
    /// Whether `TranscriptionContext.vocabularyPrompt` is used.
    var acceptsVocabularyPrompt: Bool { get }
    /// Download (first run), compile and load the model. Safe to call again once ready.
    func prepare(progress: @escaping @Sendable (ModelProgress) -> Void) async throws
    func transcribe(_ chunk: AudioChunk, context: TranscriptionContext) async throws -> ChunkTranscript
    func unload() async
}

/// Voice activity detection: speech probability per fixed-size frame of 16 kHz audio.
public protocol VoiceActivityDetector: AnyObject, Sendable {
    /// Samples per frame (FluidAudio's Silero VAD uses 4,096 = 256 ms).
    var frameSize: Int { get }
    func prepare() async throws
    /// Probabilities (0...1) for each complete frame in `samples`. Call with consecutive audio; the detector may
    /// keep state between calls. Leftover samples that don't fill a frame are buffered for the next call.
    func process(_ samples: [Float]) async throws -> [Float]
    func reset() async
}

/// Turns raw transcript text into a cleaned version (Claude Code CLI in practice).
public protocol TextCleaner: Sendable {
    /// Throws `CleanError` only.
    func clean(_ raw: String, mode: ModeConfig, glossary: String) async throws -> CleanResult
}

/// Puts the final text on the clipboard and pastes it into the focused app.
public protocol Deliverer: Sendable {
    func deliver(_ text: String) async -> DeliveryOutcome
}

/// Records microphone audio. Samples are written to disk *before* they are yielded to anyone else.
public protocol AudioRecorder: AnyObject, Sendable {
    /// Starts recording to a 16 kHz mono WAV at `fileURL`. The stream yields resampled 16 kHz mono buffers.
    func start(writingTo fileURL: URL) async throws -> AsyncStream<[Float]>
    /// Stops recording, finalises the file and returns its duration in seconds.
    func stop() async throws -> TimeInterval
    /// Stops and keeps the file (cancelled recordings keep their audio).
    func cancel() async
}

/// Keeps the Claude credential (Keychain on macOS, in memory in tests).
public protocol CredentialStore: Sendable {
    func load() throws -> ClaudeCredential?
    func save(_ credential: ClaudeCredential) throws
    func delete() throws
}

/// Runs a child process. Foundation's `Process` works on Linux and macOS, so the default implementation is in Core.
public protocol ProcessRunner: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessResult
}

public struct ProcessRequest: Sendable, Hashable {
    public var executable: URL
    public var arguments: [String]
    /// The complete environment for the child (nothing is inherited).
    public var environment: [String: String]
    public var currentDirectory: URL?
    public var stdin: Data?
    /// Kill the process after this many seconds (nil = no limit).
    public var timeout: TimeInterval?

    public init(executable: URL, arguments: [String], environment: [String: String],
                currentDirectory: URL? = nil, stdin: Data? = nil, timeout: TimeInterval? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.stdin = stdin
        self.timeout = timeout
    }
}

public struct ProcessResult: Sendable, Hashable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var elapsed: TimeInterval

    public init(exitCode: Int32, stdout: Data, stderr: Data, timedOut: Bool, elapsed: TimeInterval) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.elapsed = elapsed
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// A time source, so state machines and expiry logic can be tested.
public protocol DateSource: Sendable {
    func now() -> Date
}

public struct SystemDateSource: DateSource {
    public init() {}
    public func now() -> Date { Date() }
}

/// Counts tokens the way an engine's tokenizer would (WhisperKit's tokenizer on macOS; an approximation in tests).
public protocol TokenCounter: Sendable {
    func count(_ text: String) -> Int
}

/// Rough stand-in: about four characters per token. For tests and for when no tokenizer is loaded.
public struct ApproximateTokenCounter: TokenCounter {
    public init() {}
    public func count(_ text: String) -> Int { max(0, Int((Double(text.utf8.count) / 4).rounded(.up))) }
}
