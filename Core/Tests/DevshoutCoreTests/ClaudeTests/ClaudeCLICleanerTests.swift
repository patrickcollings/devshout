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
        let cleaner = ClaudeCLICleaner(
            installation: { installed ? installation : nil },
            credential: { credential },
            configDirectory: root.appendingPathComponent("config"),
            workingDirectory: root.appendingPathComponent("cwd"),
            runner: FoundationProcessRunner(killGracePeriod: 0.5, outputDrainTimeout: 0.5),
            host: ClaudeHostEnvironment(home: root.path, user: "patrick", tmpDir: root.path),
            temporaryDirectory: root.appendingPathComponent("tmp"))
        return Setup(cleaner: cleaner, root: root, record: record, claude: claude)
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

    @Test func hangTimesOut() async {
        let s = try! setup(mode: "hang")
        let start = Date()
        await expectCleanError({ $0 == .timedOut(after: 0.5) }) {
            _ = try await s.cleaner.clean(transcript, mode: mode(.tidy, timeout: 0.5), glossary: "")
        }
        // Generous: other suites can keep the cooperative pool busy for a while. The child would take 600 s.
        #expect(Date().timeIntervalSince(start) < 25)
    }

    @Test func slowWithinTheLimitSucceeds() async throws {
        let s = try setup(mode: "slow", extra: ["FAKE_CLAUDE_DELAY": "0.3"])
        let result = try await s.cleaner.clean(transcript, mode: mode(.tidy, timeout: 10), glossary: "")
        #expect(result.text == transcript)
        #expect(result.elapsed >= 0.3)
    }

    @Test func slowPastTheLimitTimesOut() async {
        let s = try! setup(mode: "slow", extra: ["FAKE_CLAUDE_DELAY": "60"])
        let start = Date()
        await expectCleanError({ $0 == .timedOut(after: 0.3) }) {
            _ = try await s.cleaner.clean(transcript, mode: mode(.tidy, timeout: 0.3), glossary: "")
        }
        #expect(Date().timeIntervalSince(start) < 25)
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

    @Test func emptyTranscriptIsRefused() async {
        let s = try! setup(mode: "ok-echo")
        await expectCleanError({ if case .rejectedOutput = $0 { true } else { false } }) {
            _ = try await s.cleaner.clean("  \n", mode: mode(.tidy), glossary: "")
        }
    }

    @Test func cancellationStopsClaude() async throws {
        let s = try setup(mode: "hang")
        let cleaner = s.cleaner
        let config = mode(.tidy, timeout: 30)
        let raw = transcript
        let task = Task { try await cleaner.clean(raw, mode: config, glossary: "") }
        try await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected an error")
        } catch let error as CleanError {
            #expect(error == .processFailed(exitCode: -1, message: "Cancelled"))
        }
        #expect(Date().timeIntervalSince(start) < 25)
    }
}
