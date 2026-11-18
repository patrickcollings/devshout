// What several devshout-cli commands share: engine and mode choices, the glossary, the Claude token and clean-up
// set-up, and the engine host that loads models once and runs the Core transcription pipeline.
//
// Unsure on macOS (written on Linux, type-checked there against stand-ins for DevshoutMac, never run on a Mac):
// - `SileroVAD()` relies on its default `config:` argument (FluidAudio's `VadConfig.default`) without this target
//   importing FluidAudio.
// - Reading the app's remembered auth failure from `UserDefaults(suiteName: "app.devshout.mac")`: works
//   for a non-sandboxed app's domain as far as the docs say; best effort only.
import ArgumentParser
import DevshoutCore
import DevshoutMac
import Foundation

enum EngineChoice: String, CaseIterable, ExpressibleByArgument {
    case parakeet, whisper

    var id: EngineID {
        switch self {
        case .parakeet: return .parakeetV3
        case .whisper: return .whisperLargeV3Turbo
        }
    }
}

enum TranscribeModeChoice: String, CaseIterable, ExpressibleByArgument {
    case whole, live, single

    var mode: SpikeTranscriptionMode {
        switch self {
        case .whole: return .whole
        case .live: return .live
        case .single: return .single
        }
    }
}

enum CleanupModeChoice: String, CaseIterable, ExpressibleByArgument {
    case tidy, structure

    var id: ModeID {
        switch self {
        case .tidy: return .tidy
        case .structure: return .structure
        }
    }
}

enum WhisperPromptChoice: String, CaseIterable, ExpressibleByArgument {
    case on, off, both

    var value: SpikeBenchEngine.WhisperPrompt {
        switch self {
        case .on: return .on
        case .off: return .off
        case .both: return .both
        }
    }
}

enum Files {
    static func url(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static func existing(_ path: String, what: String) throws -> URL {
        let url = url(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError("No \(what) at \(path).")
        }
        return url
    }

    /// A glossary file, parsed. Nil when no path was given.
    static func glossary(_ path: String?) throws -> (glossary: Glossary, text: String, url: URL)? {
        guard let path else { return nil }
        let url = try existing(path, what: "glossary")
        let text = try GlossaryFile(url: url).loadText()
        return (GlossaryParser.parse(text), text, url)
    }

    /// `--chunk-config file.json`: a (partial) ChunkPlannerConfig; missing keys keep their defaults.
    static func chunkConfig(_ path: String?) throws -> ChunkPlannerConfig {
        guard let path else { return .default }
        let url = try existing(path, what: "chunk config")
        do {
            return try JSONDecoder().decode(ChunkPlannerConfig.self, from: Data(contentsOf: url))
        } catch {
            throw CLIError("Couldn't read the chunk config \(path): \(error.localizedDescription)")
        }
    }
}

/// The Claude token, from CLAUDE_CODE_OAUTH_TOKEN when set, else from the Keychain item the app uses.
enum Credentials {
    static let environmentKey = "CLAUDE_CODE_OAUTH_TOKEN"

    static var environmentToken: String? {
        guard let value = ProcessInfo.processInfo.environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// For the clean-up's credential provider. Throws when the Keychain can't be read.
    static func load() throws -> ClaudeCredential? {
        if let token = environmentToken { return ClaudeCredential(token: token, createdAt: Date()) }
        return try KeychainCredentialStore().load()
    }

    /// The credential, where it came from, and any Keychain error, for status lines.
    static func current() -> (credential: ClaudeCredential?, source: SpikeConnectionReport.CredentialSource?, error: String?) {
        if let token = environmentToken {
            return (ClaudeCredential(token: token, createdAt: Date()), .environment, nil)
        }
        do {
            let stored = try KeychainCredentialStore().load()
            return (stored, stored == nil ? nil : .keychain, nil)
        } catch {
            return (nil, nil, error.localizedDescription)
        }
    }

    /// The app remembers a clean-up that failed on authentication (`ClaudeConnection`, key "claude.authFailure").
    static func appAuthFailure(for credential: ClaudeCredential?) -> String? {
        guard let defaults = UserDefaults(suiteName: "app.devshout.mac"),
              let data = defaults.data(forKey: "claude.authFailure"),
              let failure = try? JSONDecoder().decode(ClaudeAuthFailure.self, from: data) else { return nil }
        return failure.message(for: credential)
    }
}

/// Builds the clean-up exactly as the app runs it (PLAN §5.1): devshout's own empty config and working folders
/// under ~/Library/Application Support/devshout/, the token as CLAUDE_CODE_OAUTH_TOKEN, a clean environment.
enum ClaudeSetup {
    static let paths = SpikePaths.default
    static let installations = ClaudeInstallationCache(locator: ClaudeLocator())

    static func makeCleaner() -> ClaudeCLICleaner {
        ClaudeCLICleaner(installation: { try await installations.installation() },
                         credential: { try Credentials.load() },
                         configDirectory: paths.claudeConfigDirectory,
                         workingDirectory: paths.claudeWorkingDirectory)
    }

    /// Where claude is, or why it couldn't be used.
    static func locate() async -> (installation: ClaudeInstallation?, error: String?) {
        do {
            return (try await installations.installation(), nil)
        } catch let error as ClaudeLocatorError {
            return (nil, describe(error))
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    static func describe(_ error: ClaudeLocatorError) -> String {
        switch error {
        case .notFound(let searched):
            return "claude isn't installed in any usual place. Looked in: " + searched.joined(separator: ", ")
        case .versionUnreadable(let path, let output):
            let said = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(path) didn't report its version" + (said.isEmpty ? "" : ": \(said.prefix(200))")
        case .tooOld(let path, let found, let minimum):
            return "\(path) is Claude Code \(found); devshout needs \(minimum) or later (run `claude update`)"
        }
    }
}

/// Loads each engine once and runs recordings through `SpikeTranscriber` with Silero VAD.
actor EngineHost {
    let locations = ModelLocations.default
    private var engines: [EngineID: any TranscriptionEngine] = [:]
    /// The voice activity detector (`dictate-file` makes the app's chunk planner from it).
    nonisolated let vad = SileroVAD()
    private var vadReady = false

    func engine(_ id: EngineID) -> any TranscriptionEngine {
        if let existing = engines[id] { return existing }
        let made = EngineFactory.makeEngine(id, locations: locations)
        engines[id] = made
        return made
    }

    /// Downloads (first run) and loads an engine, with progress on stderr.
    func prepare(_ id: EngineID) async throws -> (seconds: TimeInterval, downloaded: Bool) {
        let downloading = !EngineFactory.isModelDownloaded(id, locations: locations)
        if downloading {
            Console.error("First run: downloading \(id.displayName) (about "
                          + "\(SpikeFormat.bytes(EngineFactory.approximateDownloadBytes(id)))) into "
                          + "\(locations.directory(for: id).path)")
        }
        let printer = ProgressPrinter(label: id.displayName)
        let start = SpikeClock.now()
        do {
            try await engine(id).prepare(progress: { printer.update($0) })
        } catch {
            printer.finish()
            throw CLIError("Couldn't load \(id.displayName): \(error.localizedDescription)")
        }
        printer.finish()
        return (SpikeClock.now() - start, downloading)
    }

    /// Loads Silero VAD once. Returns how long it took, or nil when it was already loaded.
    func prepareVAD() async throws -> TimeInterval? {
        guard !vadReady else { return nil }
        let printer = ProgressPrinter(label: "Silero VAD")
        let start = SpikeClock.now()
        do {
            try await vad.prepare(progress: { printer.update($0) })
        } catch {
            printer.finish()
            throw CLIError("Couldn't load the voice activity detector: \(error.localizedDescription)")
        }
        printer.finish()
        vadReady = true
        return SpikeClock.now() - start
    }

    /// The Whisper engine's token counter, once loaded (nil for Parakeet).
    func whisperTokenCounter(_ id: EngineID) -> WhisperTokenCounter? {
        (engine(id) as? WhisperEngine)?.tokenCounter
    }

    func transcribe(samples: [Float], engine id: EngineID, options: SpikeTranscriptionOptions,
                    audioFile: String?) async throws -> SpikeTranscriptionResult {
        let engine = engine(id)
        if options.mode != .single { _ = try await prepareVAD() }
        let counter = (engine as? WhisperEngine)?.tokenCounter
        let usesTokenizer = counter?.usesWhisperTokenizer ?? false
        let vad = self.vad
        let transcriber = SpikeTranscriber(engine: engine, vad: vad,
                                           vadRemainder: { try await vad.processRemainder() },
                                           tokenCounter: counter ?? ApproximateTokenCounter(),
                                           tokenCounterName: usesTokenizer ? "WhisperKit tokenizer" : "approximate counter")
        return try await transcriber.run(samples: samples, options: options, audioFile: audioFile)
    }

    func unload(_ id: EngineID) async {
        if let engine = engines.removeValue(forKey: id) { await engine.unload() }
    }

    func unloadAll() async {
        for id in Array(engines.keys) { await unload(id) }
        if vadReady {
            await vad.unload()
            vadReady = false
        }
    }
}

/// 16 kHz mono samples from any WAV (or other audio file AVFoundation reads).
func readAudio(_ url: URL) throws -> [Float] {
    do {
        return try WavFileReader.read16kMono(url)
    } catch {
        throw CLIError(error.localizedDescription)
    }
}
