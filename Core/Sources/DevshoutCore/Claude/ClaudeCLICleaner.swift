import Foundation

/// `TextCleaner` that runs the Claude Code CLI (`claude -p`) on the user's own subscription.
///
/// Every failure is a `CleanError`, and every `CleanError` means "paste the raw text instead".
public struct ClaudeCLICleaner: TextCleaner {
    public typealias InstallationProvider = @Sendable () async throws -> ClaudeInstallation?
    public typealias CredentialProvider = @Sendable () throws -> ClaudeCredential?

    private let installation: InstallationProvider
    private let credential: CredentialProvider
    private let configDirectory: URL
    private let workingDirectory: URL
    private let runner: ProcessRunner
    private let host: ClaudeHostEnvironment
    private let temporaryDirectory: URL

    /// - Parameters:
    ///   - installation: where `claude` is (e.g. `ClaudeInstallationCache.installation`). Nil or a throw means
    ///     `CleanError.claudeNotFound`.
    ///   - credential: the `claude setup-token` token from the Keychain. Nil or a throw means `.notConnected`.
    ///   - configDirectory: devshout's own, empty `CLAUDE_CONFIG_DIR` (created if missing).
    ///   - workingDirectory: an empty folder to run `claude` in (created if missing).
    ///   - temporaryDirectory: where the system prompt file is written for the length of one run.
    public init(installation: @escaping InstallationProvider,
                credential: @escaping CredentialProvider,
                configDirectory: URL,
                workingDirectory: URL,
                runner: ProcessRunner = FoundationProcessRunner(),
                host: ClaudeHostEnvironment = .current,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.installation = installation
        self.credential = credential
        self.configDirectory = configDirectory
        self.workingDirectory = workingDirectory
        self.runner = runner
        self.host = host
        self.temporaryDirectory = temporaryDirectory
    }

    public func clean(_ raw: String, mode: ModeConfig, glossary: String) async throws -> CleanResult {
        guard mode.id.usesClaude, let systemPrompt = PromptBuilder.systemPrompt(mode: mode, glossary: glossary) else {
            throw CleanError.rejectedOutput(reason: "\(mode.id.displayName) mode doesn't use Claude")
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CleanError.rejectedOutput(reason: "Nothing to clean up: the transcript is empty")
        }

        let token: ClaudeCredential?
        do { token = try credential() } catch { throw CleanError.notConnected }
        guard let token, !token.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CleanError.notConnected
        }

        let found: ClaudeInstallation?
        do { found = try await installation() } catch { throw CleanError.claudeNotFound }
        guard let found else { throw CleanError.claudeNotFound }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            throw CleanError.processFailed(exitCode: -1, message: "Couldn't create devshout's Claude folders: \(error.localizedDescription)")
        }

        let promptFile = temporaryDirectory.appendingPathComponent("devshout-system-\(UUID().uuidString).md")
        do {
            try Data(systemPrompt.utf8).write(to: promptFile, options: .atomic)
        } catch {
            throw CleanError.processFailed(exitCode: -1, message: "Couldn't write the system prompt: \(error.localizedDescription)")
        }
        defer { try? fileManager.removeItem(at: promptFile) }

        let timeout = mode.timeout > 0 ? mode.timeout : nil
        let invocation = ClaudeInvocation(executable: found.url,
                                          model: mode.claudeModel,
                                          systemPrompt: .file(promptFile),
                                          stdin: PromptBuilder.userMessage(transcript: raw),
                                          credential: token,
                                          configDirectory: configDirectory,
                                          workingDirectory: workingDirectory,
                                          host: host,
                                          timeout: timeout)

        let run: ProcessResult
        do {
            run = try await runner.run(invocation.processRequest)
        } catch is CancellationError {
            throw CleanError.processFailed(exitCode: -1, message: "Cancelled")
        } catch {
            if !fileManager.isExecutableFile(atPath: found.url.path) { throw CleanError.claudeNotFound }
            throw CleanError.processFailed(exitCode: -1, message: "Couldn't start claude: \(error)")
        }
        if run.timedOut { throw CleanError.timedOut(after: mode.timeout) }

        let text: String
        switch ClaudeResultParser.interpret(run) {
        case .success(let cleaned): text = cleaned
        case .failure(let error): throw error
        }

        var warnings: [String] = []
        switch mode.id {
        case .tidy:
            if let reason = TidyLengthCheck.failureReason(raw: raw, output: text) {
                throw CleanError.rejectedOutput(reason: reason)
            }
        case .structure:
            warnings = CoverageCheck.warnings(raw: raw, output: text,
                                              glossaryTerms: CoverageCheck.glossaryTerms(in: glossary))
        case .raw:
            break
        }

        return CleanResult(text: text, model: mode.claudeModel, elapsed: run.elapsed, warnings: warnings)
    }
}
