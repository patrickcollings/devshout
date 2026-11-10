import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Timings for `devshout-cli claude-probe` (PLAN §9, Phase 0): how long `claude` takes to start, to answer a minimal
/// clean-up, and to answer once it has been started early ("pre-warmed") with its stdin left open.
public enum ClaudeProbe {
    /// The sentence the probe cleans up.
    public static let probeSentence = "um so can you check the corsia flag on my supply before friday"

    /// The `claude --version` request `ClaudeLocator.version(of:)` makes: pure start-up, no network.
    public static func versionRequest(for installation: ClaudeInstallation, home: String,
                                      lang: String = ProcessInfo.processInfo.environment["LANG"] ?? "en_GB.UTF-8",
                                      timeout: TimeInterval = 15) -> ProcessRequest {
        ProcessRequest(executable: installation.url, arguments: ["--version"],
                       environment: [
                           "HOME": home,
                           "PATH": ClaudeInvocation.path(for: installation.url, extraPath: installation.extraPath),
                           "LANG": lang,
                           "DISABLE_AUTOUPDATER": "1",
                           "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                       ],
                       currentDirectory: nil, timeout: timeout)
    }

    /// Runs `request` `runs` times and returns each run's spawn → exit time; failed runs are described in `failures`.
    public static func time(_ request: ProcessRequest, runs: Int,
                            runner: ProcessRunner = FoundationProcessRunner()) async -> (times: [TimeInterval], failures: [String]) {
        var times: [TimeInterval] = []
        var failures: [String] = []
        for run in 1...max(1, runs) {
            do {
                let result = try await runner.run(request)
                if result.timedOut {
                    failures.append("run \(run): timed out after \(SpikeFormat.seconds(result.elapsed))")
                } else if result.exitCode != 0 {
                    let said = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                    failures.append("run \(run): exit code \(result.exitCode)\(said.isEmpty ? "" : ": \(said.prefix(200))")")
                } else {
                    times.append(result.elapsed)
                }
            } catch {
                failures.append("run \(run): \(error)")
            }
        }
        return (times, failures)
    }

    /// The Tidy settings the probe uses: Haiku, as the app's Tidy default.
    public static func probeMode(model: String = "haiku", timeout: TimeInterval = 60) -> ModeConfig {
        ModeConfig(id: .tidy, claudeModel: model, timeout: timeout)
    }

    /// The exact `claude -p` request a clean-up makes, for the pre-warm run. The system prompt goes in a file in
    /// `temporaryDirectory`; delete `promptFile` afterwards.
    public static func cleanUpRequest(installation: ClaudeInstallation, credential: ClaudeCredential, mode: ModeConfig,
                                      glossary: String = "", transcript: String = probeSentence, paths: SpikePaths,
                                      host: ClaudeHostEnvironment = .current,
                                      temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws
        -> (request: ProcessRequest, promptFile: URL) {
        guard let systemPrompt = PromptBuilder.systemPrompt(mode: mode, glossary: glossary) else {
            throw SpikeError.invalidInput("\(mode.id.displayName) mode doesn't use Claude.")
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.claudeConfigDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.claudeWorkingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let promptFile = temporaryDirectory.appendingPathComponent("devshout-system-\(UUID().uuidString).md")
        try Data(systemPrompt.utf8).write(to: promptFile, options: .atomic)
        let invocation = ClaudeInvocation(executable: installation.url, model: mode.claudeModel,
                                          systemPrompt: .file(promptFile),
                                          stdin: PromptBuilder.userMessage(transcript: transcript),
                                          credential: credential, configDirectory: paths.claudeConfigDirectory,
                                          workingDirectory: paths.claudeWorkingDirectory, host: host,
                                          timeout: mode.timeout > 0 ? mode.timeout : nil,
                                          extraPath: installation.extraPath)
        return (invocation.processRequest, promptFile)
    }
}

/// What a pre-warmed run measured.
public struct PrewarmedRun: Sendable, Hashable {
    /// Exit code, output, `timedOut`, and `elapsed` from spawn to exit.
    public var result: ProcessResult
    /// When stdin was written, in seconds after spawn.
    public var writtenAt: TimeInterval
    /// From writing stdin to exit: the wait a pre-warmed clean-up leaves after the user stops talking.
    public var afterWrite: TimeInterval
    /// From writing stdin to the first byte on stdout, if any came.
    public var firstByteAfterWrite: TimeInterval?
    /// Output arrived before stdin was written (the process didn't wait for its input).
    public var outputBeforeWrite: Bool

    public init(result: ProcessResult, writtenAt: TimeInterval, afterWrite: TimeInterval,
                firstByteAfterWrite: TimeInterval?, outputBeforeWrite: Bool) {
        self.result = result
        self.writtenAt = writtenAt
        self.afterWrite = afterWrite
        self.firstByteAfterWrite = firstByteAfterWrite
        self.outputBeforeWrite = outputBeforeWrite
    }
}

/// A child process started with its stdin left open, to be written later: the pre-warm idea of PLAN §5.1 (spawn
/// `claude -p` when recording starts, write the transcript when it stops). Foundation `Process`, Linux and macOS.
///
/// The child gets exactly `request.environment`, `request.arguments` and `request.currentDirectory`;
/// `request.stdin` is ignored (pass the data to `finish`). `request.timeout` counts from the moment stdin is written.
public final class PrewarmedProcess: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let exited = DispatchSemaphore(value: 0)
    private let drained = DispatchGroup()
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var firstByteAt: TimeInterval?
    private var startedAt: TimeInterval = 0
    private let timeout: TimeInterval?
    private let killGracePeriod: TimeInterval

    private static let ignoreSIGPIPE: Void = {
        _ = signal(SIGPIPE, SIG_IGN)
    }()

    private init(request: ProcessRequest, killGracePeriod: TimeInterval) {
        timeout = request.timeout
        self.killGracePeriod = killGracePeriod
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.environment = request.environment
        if let cwd = request.currentDirectory { process.currentDirectoryURL = cwd }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [exited] _ in exited.signal() }
    }

    /// Spawns the process now. Its stdin stays open until `finish`.
    public static func start(_ request: ProcessRequest, killGracePeriod: TimeInterval = 2) throws -> PrewarmedProcess {
        Self.ignoreSIGPIPE
        let child = PrewarmedProcess(request: request, killGracePeriod: killGracePeriod)
        // Launch from a thread of our own with the termination signals unblocked, so the child inherits a signal mask
        // that lets `terminate()` stop it (Foundation on Linux doesn't reset the mask).
        let launched = DispatchSemaphore(value: 0)
        let box = LaunchBox()
        Thread.detachNewThread {
            Self.unblockTerminationSignals()
            do {
                try child.launch()
            } catch {
                box.error = error
            }
            launched.signal()
        }
        launched.wait()
        if let error = box.error {
            throw ProcessRunnerError.launchFailed(executable: request.executable.path,
                                                  message: (error as NSError).localizedDescription)
        }
        return child
    }

    private func launch() throws {
        startedAt = SpikeClock.now()
        try process.run()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        try? stdinPipe.fileHandleForReading.close()
        drain(stdoutPipe.fileHandleForReading, isStdout: true)
        drain(stderrPipe.fileHandleForReading, isStdout: false)
    }

    /// Seconds since spawn.
    public var age: TimeInterval { SpikeClock.now() - startedAt }

    /// Writes `stdin`, closes it and waits for the process to exit (or the request's timeout, counted from now).
    public func finish(stdin data: Data) async -> PrewarmedRun {
        await withCheckedContinuation { (continuation: CheckedContinuation<PrewarmedRun, Never>) in
            Thread.detachNewThread {
                continuation.resume(returning: self.finishBlocking(data))
            }
        }
    }

    /// Stops the process (SIGTERM, then SIGKILL after the grace period) without writing anything.
    public func terminate() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        kill(pid, SIGTERM)
        if exited.wait(timeout: .now() + max(0, killGracePeriod)) == .timedOut, process.isRunning {
            kill(pid, SIGKILL)
        } else {
            exited.signal() // put back what we took, for finishBlocking
        }
    }

    private func finishBlocking(_ data: Data) -> PrewarmedRun {
        let writtenAt = SpikeClock.now()
        let outputBeforeWrite: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return firstByteAt != nil
        }()
        let handle = stdinPipe.fileHandleForWriting
        if !data.isEmpty { try? handle.write(contentsOf: data) }
        try? handle.close()

        var timedOut = false
        var didExit = true
        if let timeout {
            if exited.wait(timeout: .now() + max(0, timeout)) == .timedOut {
                timedOut = true
                let pid = process.processIdentifier
                if process.isRunning { kill(pid, SIGTERM) }
                if exited.wait(timeout: .now() + max(0, killGracePeriod)) == .timedOut {
                    if process.isRunning { kill(pid, SIGKILL) }
                    didExit = exited.wait(timeout: .now() + max(0.5, killGracePeriod)) == .success
                }
            }
        } else {
            exited.wait()
        }
        if didExit { process.waitUntilExit() }
        _ = drained.wait(timeout: .now() + 1)
        let end = SpikeClock.now()

        let exitCode: Int32
        if !didExit {
            exitCode = 128 + SIGKILL
        } else {
            switch process.terminationReason {
            case .exit: exitCode = process.terminationStatus
            case .uncaughtSignal: exitCode = 128 + process.terminationStatus
            @unknown default: exitCode = process.terminationStatus
            }
        }
        lock.lock()
        let out = stdoutData
        let err = stderrData
        let firstByte = firstByteAt
        lock.unlock()
        let result = ProcessResult(exitCode: exitCode, stdout: out, stderr: err, timedOut: timedOut,
                                   elapsed: end - startedAt)
        return PrewarmedRun(result: result, writtenAt: writtenAt - startedAt, afterWrite: end - writtenAt,
                            firstByteAfterWrite: firstByte.map { max(0, $0 - writtenAt) },
                            outputBeforeWrite: outputBeforeWrite)
    }

    private func drain(_ handle: FileHandle, isStdout: Bool) {
        drained.enter()
        Thread.detachNewThread { [self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                if isStdout {
                    if firstByteAt == nil { firstByteAt = SpikeClock.now() }
                    stdoutData.append(chunk)
                } else {
                    stderrData.append(chunk)
                }
                lock.unlock()
            }
            try? handle.close()
            drained.leave()
        }
    }

    private static func unblockTerminationSignals() {
        var set = sigset_t()
        sigemptyset(&set)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE] { sigaddset(&set, signal) }
        pthread_sigmask(SIG_UNBLOCK, &set, nil)
    }
}

private final class LaunchBox: @unchecked Sendable {
    var error: Error?
}
