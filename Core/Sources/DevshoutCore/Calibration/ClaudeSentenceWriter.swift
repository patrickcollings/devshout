import Foundation

/// Asks Claude for the calibration script's glossary sentences: one `claude -p` call, set up exactly like a
/// clean-up (`ClaudeInvocation`: the subscription token, devshout's own empty config folder, an empty working
/// folder, tools off, a clean environment), with its own instructions instead of a mode's.
///
/// Every failure is a `CleanError`. The caller (`CalibrationScriptBuilder.script(glossary:writer:)`) treats any of
/// them as "use the built-in sentences", so calibration never depends on Claude.
public struct ClaudeSentenceWriter: Sendable {
    public typealias InstallationProvider = @Sendable () async throws -> ClaudeInstallation?
    public typealias CredentialProvider = @Sendable () throws -> ClaudeCredential?

    private let installation: InstallationProvider
    private let credential: CredentialProvider
    private let configDirectory: URL
    private let workingDirectory: URL
    private let runner: ProcessRunner
    private let host: ClaudeHostEnvironment
    /// Haiku: the sentences are short and simple, and it answers in a few seconds.
    public var model: String
    /// Calibration waits this long at most before using the built-in sentences.
    public var timeout: TimeInterval

    public init(installation: @escaping InstallationProvider,
                credential: @escaping CredentialProvider,
                configDirectory: URL,
                workingDirectory: URL,
                runner: ProcessRunner = FoundationProcessRunner(),
                host: ClaudeHostEnvironment = .current,
                model: String = "haiku",
                timeout: TimeInterval = 30) {
        self.installation = installation
        self.credential = credential
        self.configDirectory = configDirectory
        self.workingDirectory = workingDirectory
        self.runner = runner
        self.host = host
        self.model = model
        self.timeout = timeout
    }

    /// Claude's answer, unchecked: `CalibrationScriptBuilder.sentences(fromClaude:for:)` decides what is usable.
    public func write(_ request: CalibrationSentenceRequest) async throws -> String {
        let token: ClaudeCredential?
        do { token = try credential() } catch { throw CleanError.notConnected }
        guard let token, !token.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CleanError.notConnected
        }
        let found: ClaudeInstallation?
        do { found = try await installation() } catch { throw CleanError.claudeNotFound }
        guard let found else { throw CleanError.claudeNotFound }

        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        } catch {
            throw CleanError.processFailed(exitCode: -1, message: "Couldn't create devshout's Claude folders: \(error.localizedDescription)")
        }

        let invocation = ClaudeInvocation(executable: found.url,
                                          model: model,
                                          systemPrompt: .inline(request.systemPrompt),
                                          stdin: request.message,
                                          credential: token,
                                          configDirectory: configDirectory,
                                          workingDirectory: workingDirectory,
                                          host: host,
                                          timeout: timeout > 0 ? timeout : nil,
                                          extraPath: found.extraPath,
                                          prompt: CalibrationScriptBuilder.claudePrompt)
        let run: ProcessResult
        do {
            run = try await runner.run(invocation.processRequest)
        } catch is CancellationError {
            throw CleanError.processFailed(exitCode: -1, message: "Cancelled")
        } catch {
            throw CleanError.processFailed(exitCode: -1, message: "Couldn't start claude: \(error)")
        }
        if run.timedOut { throw CleanError.timedOut(after: timeout) }
        switch ClaudeResultParser.interpret(run) {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }
}
