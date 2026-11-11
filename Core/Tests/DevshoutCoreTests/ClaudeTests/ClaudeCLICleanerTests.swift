import Foundation
import Testing
@testable import DevshoutCore

/// End-to-end: the real `FoundationProcessRunner` against `scripts/fake-claude.sh`.
@Suite struct ClaudeCLICleanerTests {
    let transcript = "so the plan is to check the CORSIA flag on AB-1234 in My Supply and then ship it on Tuesday"

    struct Setup {
        var cleaner: ClaudeCLICleaner
        var root: URL
        var record: URL
        var claude: URL
        var runner: RecordingRunner
    }

    func setup(mode: String, extra: [String: String] = [:],
               credential: ClaudeCredential? = ClaudeTestSupport.credential,
               installed: Bool = true) throws -> Setup {
        let root = try ClaudeTestSupport.temporaryDirectory("cleaner")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let record = root.appendingPathComponent("record.txt")
        var env = extra
        env["FAKE_CLAUDE_RECORD"] = record.path
        let claude = try ClaudeTestSupport.fakeClaude(mode: mode, extraEnvironment: env, in: bin,
                                                      settingsDirectory: root.appendingPathComponent("config"))
        let installation = ClaudeInstallation(url: claude, version: ClaudeVersion(2, 1, 300))
        let runner = RecordingRunner(FoundationProcessRunner(killGracePeriod: 0.5, outputDrainTimeout: 0.5))
        let cleaner = ClaudeCLICleaner(
            installation: { installed ? installation : nil },
            credential: { credential },
            configDirectory: root.appendingPathComponent("config"),
            workingDirectory: root.appendingPathComponent("cwd"),
            runner: runner,
            host: ClaudeHostEnvironment(home: root.path, user: "patrick", tmpDir: root.path),
            temporaryDirectory: root.appendingPathComponent("tmp"))
        return Setup(cleaner: cleaner, root: root, record: record, claude: claude, runner: runner)
    }

    func mode(_ id: ModeID, timeout: TimeInterval? = nil) -> ModeConfig {
        var config = ModeConfig.defaults[id]!
        if let timeout { config.timeout = timeout }
        return config
    }

    func expectCleanError(_ expected: (CleanError) -> Bool, _ body: () async throws -> Void,
                          sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            try await body()
            Issue.record("expected a CleanError", sourceLocation: sourceLocation)
        } catch let error as CleanError {
            #expect(expected(error), "unexpected \(error)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("not a CleanError: \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func tidyEchoSucceeds() async throws {
        let s = try setup(mode: "ok-echo")
        let result = try await s.cleaner.clean(transcript, mode: mode(.tidy), glossary: "- **CORSIA**")
        #expect(result.text == transcript)
        #expect(result.model == "haiku")
        #expect(result.warnings.isEmpty)
        #expect(result.elapsed > 0)
    }

    @Test func theChildGetsTheCleanInvocation() async throws {
        let s = try setup(mode: "ok-echo")
        _ = try await s.cleaner.clean(transcript, mode: mode(.structure), glossary: "- **CORSIA** — aviation scheme")
        let record = try String(contentsOf: s.record, encoding: .utf8)
        let parts = record.components(separatedBy: "--- env\n")
        let args = parts[0].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(args.starts(with: ["-p", PromptBuilder.userPrompt, "--model", "sonnet", "--system-prompt-file"]))
        #expect(args.contains("--strict-mcp-config"))
        #expect(!args.contains("--bare"))

        let env = Dictionary(parts[1].split(separator: "\n").compactMap { line -> (String, String)? in
            guard let eq = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<eq]), String(line[line.index(after: eq)...]))
        }, uniquingKeysWith: { a, _ in a })
        #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == "sk-ant-oat01-test-token")
        #expect(env["CLAUDE_CONFIG_DIR"] == s.root.appendingPathComponent("config").path)
        #expect(env["HOME"] == s.root.path)
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        // Only what devshout sets, plus what the wrapper and the shell add themselves.
        let allowed: Set<String> = Set(ClaudeInvocation(
            executable: s.claude, model: "", systemPrompt: .inline(""), stdin: "", credential: ClaudeTestSupport.credential,
            configDirectory: s.root, workingDirectory: s.root, host: ClaudeTestSupport.host).environment.keys)
            .union(["FAKE_CLAUDE_MODE", "FAKE_CLAUDE_RECORD", "PWD", "OLDPWD", "SHLVL", "_", "__CF_USER_TEXT_ENCODING"])
        #expect(Set(env.keys).subtracting(allowed).isEmpty, "unexpected: \(Set(env.keys).subtracting(allowed))")

        // The system prompt file is gone after the run, and the folders were made.
        let tmpContents = try FileManager.default.contentsOfDirectory(atPath: s.root.appendingPathComponent("tmp").path)
        #expect(tmpContents.isEmpty)
        #expect(FileManager.default.fileExists(atPath: s.root.appendingPathComponent("cwd").path))
    }

    @Test func fencedOutputIsUnwrapped() async throws {
        // The fenced mode wraps the echo in a code fence, which must be stripped.
        let s = try setup(mode: "fenced")
        let raw = "fix AB-77 please"
        let result = try await s.cleaner.clean(raw, mode: mode(.structure), glossary: "- **CORSIA**")
        #expect(result.text == raw)
        #expect(result.warnings.isEmpty)
    }

    @Test func structureCoverageWarning() async throws {
        let s = try setup(mode: "essay")
        let result = try await s.cleaner.clean("look at AB-1234 and the CORSIA total of 42",
                                               mode: mode(.structure), glossary: "- **CORSIA** — scheme")
        #expect(result.warnings == ["may have dropped: AB-1234, 42, CORSIA"])
    }

    @Test func essayFailsTidy() async {
        let s = try! setup(mode: "essay")
        await expectCleanError({ if case .rejectedOutput = $0 { true } else { false } }) {
            _ = try await s.cleaner.clean(transcript, mode: mode(.tidy), glossary: "")
        }
    }

    @Test func authFailure() async {
        let s = try! setup(mode: "auth-fail")
        await expectCleanError({ if case .authFailed = $0 { true } else { false } }) {
            _ = try await s.cleaner.clean(transcript, mode: mode(.tidy), glossary: "")
        }
    }

    @Test func rateLimit() async {
        let s = try! setup(mode: "rate-limit")
        await expectCleanError({ if case .processFailed(1, _) = $0 { true } else { false } }) {
            _ = try await s.cleaner.clean(transcript, mode: mode(.tidy), glossary: "")
        }
    }

    @Test func failure() async {
        let s = try! setup(mode: "fail")
        await expectCleanError({
            if case .processFailed(1, let message) = $0 { message.contains("something went wrong") } else { false }
        }) {
            _ = try await s.cleaner.clean(transcript, mode: mode(.tidy), glossary: "")
        }
    }

    @Test func garbage() async {
        let s = try! setup(mode: "garbage")
        await expectCleanError({ if case .rejectedOutput = $0 { true } else { false } }) {
            _ = try await s.cleaner.clean(transcript, mode: mode(.tidy), glossary: "")
        }
    }

    @Test func emptyResult() async {
        let s = try! setup(mode: "empty")
        await expectCleanError({ if case .rejectedOutput = $0 { true } else { false } }) {
            _ = try await s.cleaner.clean(transcript, mode: mode(.tidy), glossary: "")
        }
    }

    /// The child was stopped at the limit rather than waited for. `elapsed` is the runner's own measurement, from
    /// spawning the child to its exit, taken on the runner's thread: limit + SIGTERM (+ grace + SIGKILL) + draining
    /// the pipes, about 2 s at most with this runner's settings. It doesn't include the wait for a task thread
    /// before and after, which is what made a stopwatch around `clean` take 36-44 s on CI.
    func expectStoppedAtTheLimit(_ s: Setup, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(s.runner.results.count == 1, sourceLocation: sourceLocation)
        guard let run = s.runner.results.first else { return }
        #expect(run.timedOut, sourceLocation: sourceLocation)
        #expect(run.elapsed < 10, "the child ran for \(run.elapsed) s", sourceLocation: sourceLocation)
    }

    @Test func hangTimesOut() async {
        let s = try! setup(mode: "hang")  // the child would take 600 s
        await expectCleanError({ $0 == .timedOut(after: 0.5) }) {
            _ = try await s.cleaner.clean(transcript, mode: mode(.tidy, timeout: 0.5), glossary: "")
        }
        expectStoppedAtTheLimit(s)
    }

    @Test func slowWithinTheLimitSucceeds() async throws {
        let s = try setup(mode: "slow", extra: ["FAKE_CLAUDE_DELAY": "0.3"])
        let result = try await s.cleaner.clean(transcript, mode: mode(.tidy, timeout: 10), glossary: "")
        #expect(result.text == transcript)
        #expect(result.elapsed >= 0.3)
    }

    @Test func slowPastTheLimitTimesOut() async {
        let s = try! setup(mode: "slow", extra: ["FAKE_CLAUDE_DELAY": "60"])
        await expectCleanError({ $0 == .timedOut(after: 0.3) }) {
            _ = try await s.cleaner.clean(transcript, mode: mode(.tidy, timeout: 0.3), glossary: "")
        }
        expectStoppedAtTheLimit(s)
    }

    // MARK: A run that timed out after answering

    /// A cleaner whose `claude` is a stub: the run "times out" with `stdout` already printed.
    func timedOutCleaner(stdout: String, exitCode: Int32 = 143) throws -> ClaudeCLICleaner {
        let root = try ClaudeTestSupport.temporaryDirectory("cleaner-stub")
        let runner = StubRunner { _ in StubRunner.result(stdout: stdout, exitCode: exitCode, timedOut: true, elapsed: 20) }
        return ClaudeCLICleaner(
            installation: { ClaudeInstallation(url: URL(fileURLWithPath: "/usr/bin/true"), version: ClaudeVersion(2, 1, 300)) },
            credential: { ClaudeTestSupport.credential },
            configDirectory: root.appendingPathComponent("config"),
            workingDirectory: root.appendingPathComponent("cwd"),
            runner: runner,
            host: ClaudeTestSupport.host,
            temporaryDirectory: root.appendingPathComponent("tmp"))
    }

    func resultJSON(_ text: String, isError: Bool = false, subtype: String = "success") -> String {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"type":"result","subtype":"\#(subtype)","is_error":\#(isError),"result":"\#(escaped)"}"# + "\n"
    }

    @Test func aTimedOutRunThatHadAlreadyAnsweredIsUsed() async throws {
        // The runner stopped claude with SIGTERM (exit code 143) after the limit, but the result was on stdout.
        let cleaner = try timedOutCleaner(stdout: resultJSON(transcript))
        let result = try await cleaner.clean(transcript, mode: mode(.tidy, timeout: 20), glossary: "")
        #expect(result.text == transcript)
        #expect(result.elapsed == 20)
        // SIGKILL (137) after ignoring SIGTERM is no different.
        let killed = try timedOutCleaner(stdout: "warming up\n" + resultJSON(transcript), exitCode: 137)
        #expect(try await killed.clean(transcript, mode: mode(.structure, timeout: 45), glossary: "").text == transcript)
    }

    @Test func aTimedOutRunWithoutACompleteResultStillTimesOut() async throws {
        let whole = resultJSON(transcript)
        let cases = [
            "",                                             // nothing printed
            String(whole.prefix(whole.count / 2)),          // cut off part-way through the result
            "Thinking…\n",                                  // only noise
            resultJSON("Claude AI usage limit reached.", isError: true),
            resultJSON("", subtype: "error_during_execution"),
            resultJSON(""),                                 // a "successful" result with no text
        ]
        for stdout in cases {
            let cleaner = try timedOutCleaner(stdout: stdout)
            await expectCleanError({ $0 == .timedOut(after: 20) }) {
                _ = try await cleaner.clean(transcript, mode: mode(.tidy, timeout: 20), glossary: "")
            }
        }
    }

    @Test func aTimedOutAnswerStillHasToPassTheSanityChecks() async throws {
        let cleaner = try timedOutCleaner(stdout: resultJSON("Sure."))
        await expectCleanError({ if case .rejectedOutput = $0 { true } else { false } }) {
            _ = try await cleaner.clean(transcript, mode: mode(.tidy, timeout: 20), glossary: "")
        }
    }

    @Test func lingeringAfterTheAnswerIsNotATimeout() async throws {
        // End to end: the fake prints its result and then stays running until the runner stops it.
        let s = try setup(mode: "linger")
        let result = try await s.cleaner.clean(transcript, mode: mode(.tidy, timeout: 2), glossary: "")
        #expect(result.text == transcript)
    }

    @Test func noCredentialMeansNotConnected() async {
        let s = try! setup(mode: "ok-echo", credential: nil)
        await expectCleanError({ $0 == .notConnected }) {
            _ = try await s.cleaner.clean(transcript, mode: mode(.tidy), glossary: "")
        }
    }

    @Test func throwingCredentialStoreMeansNotConnected() async {
        struct KeychainDown: Error {}
        let cleaner = ClaudeCLICleaner(
            installation: { nil }, credential: { throw KeychainDown() },
            configDirectory: URL(fileURLWithPath: "/tmp/x"), workingDirectory: URL(fileURLWithPath: "/tmp/y"))
        await expectCleanError({ $0 == .notConnected }) {
            _ = try await cleaner.clean(transcript, mode: mode(.tidy), glossary: "")
        }
    }

    @Test func noBinaryMeansClaudeNotFound() async {
        let s = try! setup(mode: "ok-echo", installed: false)
        await expectCleanError({ $0 == .claudeNotFound }) {
            _ = try await s.cleaner.clean(transcript, mode: mode(.tidy), glossary: "")
        }
    }

    @Test func vanishedBinaryMeansClaudeNotFound() async throws {
        let s = try setup(mode: "ok-echo")
        try FileManager.default.removeItem(at: s.claude)
        await expectCleanError({ $0 == .claudeNotFound }) {
            _ = try await s.cleaner.clean(transcript, mode: mode(.tidy), glossary: "")
        }
    }

    @Test func rawIsRefused() async {
        let s = try! setup(mode: "ok-echo")
        await expectCleanError({ if case .rejectedOutput = $0 { true } else { false } }) {
            _ = try await s.cleaner.clean(transcript, mode: mode(.raw), glossary: "")
        }
        #expect(!FileManager.default.fileExists(atPath: s.record.path))
    }

    // MARK: Custom modes

    let commit = CustomMode(name: "Commit message", instructions: "Write a Git commit message.",
                            claudeModel: "sonnet", timeout: 30).config

    @Test func aCustomModeIsSentInItsOwnFrame() async throws {
        let s = try setup(mode: "ok-echo")
        let result = try await s.cleaner.clean(transcript, mode: commit, glossary: "- **CORSIA**")
        // The echo is the transcript as it arrived on stdin: the same wrapper as for the built-ins.
        #expect(result.text == transcript)
        #expect(result.model == "sonnet")
        #expect(result.warnings.isEmpty)
        let record = try String(contentsOf: s.record, encoding: .utf8)
        let args = record.components(separatedBy: "--- env\n")[0]
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(args.starts(with: ["-p", PromptBuilder.userPrompt, "--model", "sonnet", "--system-prompt-file"]))
        #expect(!args.contains("--bare"))
    }

    @Test func aCustomModeHasNoLengthCheck() async throws {
        // The essay that Tidy rejects: a custom mode may write far more, or far less, than was said.
        let s = try setup(mode: "essay")
        let result = try await s.cleaner.clean(transcript, mode: commit, glossary: "")
        #expect(result.text.hasPrefix("Great question!"))
    }

    @Test func aCustomModeGetsTheCoverageWarning() async throws {
        let s = try setup(mode: "essay")
        let result = try await s.cleaner.clean("look at AB-1234 and the CORSIA total of 42",
                                               mode: commit, glossary: "- **CORSIA** — scheme")
        #expect(result.warnings == ["may have dropped: AB-1234, 42, CORSIA"])
    }

    @Test func anEmptyResultFromACustomModeIsRejected() async {
        let s = try! setup(mode: "empty")
        await expectCleanError({ if case .rejectedOutput = $0 { true } else { false } }) {
            _ = try await s.cleaner.clean(transcript, mode: commit, glossary: "")
        }
    }

    @Test func aCustomModeWithoutInstructionsSendsNothing() async {
        let s = try! setup(mode: "ok-echo")
        var blank = commit
        blank.customInstructions = nil
        await expectCleanError({ $0 == .rejectedOutput(reason: ClaudeCLICleaner.noInstructionsReason) }) {
            _ = try await s.cleaner.clean(transcript, mode: blank, glossary: "")
        }
        #expect(!FileManager.default.fileExists(atPath: s.record.path))
    }

    @Test func whichChecksApply() {
        #expect(OutputChecks.forMode(.raw) == .none)
        #expect(OutputChecks.forMode(.tidy) == .length)
        #expect(OutputChecks.forMode(.structure) == .coverage)
        #expect(OutputChecks.forMode(.custom()) == .coverage)
    }

    @Test func emptyTranscriptIsRefused() async {
        let s = try! setup(mode: "ok-echo")
        await expectCleanError({ if case .rejectedOutput = $0 { true } else { false } }) {
            _ = try await s.cleaner.clean("  \n", mode: mode(.tidy), glossary: "")
        }
    }

    // The child runs for 600 s unless cancelling stops it, so finishing at all (inside the time limit, which is far
    // above any wait for a task thread) is the proof. No stopwatch, for the reason given at expectStoppedAtTheLimit.
    @Test(.timeLimit(.minutes(3))) func cancellationStopsClaude() async throws {
        let s = try setup(mode: "hang")
        let cleaner = s.cleaner
        let config = mode(.tidy, timeout: 30)
        let raw = transcript
        let task = Task { try await cleaner.clean(raw, mode: config, glossary: "") }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected an error")
        } catch let error as CleanError {
            #expect(error == .processFailed(exitCode: -1, message: "Cancelled"))
        }
    }
}
