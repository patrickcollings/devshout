import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Testing
@testable import DevshoutCore

@Suite struct TokenHealthTests {
    static let created = Date(timeIntervalSince1970: 1_794_312_000)  // 2026-11-10 12:00 UTC
    static func at(days: Double) -> Date { created.addingTimeInterval(days * 86_400) }

    @Test func freshTokenIsOK() {
        #expect(TokenHealth.evaluate(createdAt: Self.created, now: Self.created) == .ok)
        #expect(TokenHealth.evaluate(createdAt: Self.created, now: Self.at(days: 334.9)) == .ok)
    }

    @Test func warnsFromThirtyDaysBefore() {
        #expect(TokenHealth.evaluate(createdAt: Self.created, now: Self.at(days: 335)) == .expiringSoon(daysLeft: 30))
        #expect(TokenHealth.evaluate(createdAt: Self.created, now: Self.at(days: 350.5)) == .expiringSoon(daysLeft: 15))
        #expect(TokenHealth.evaluate(createdAt: Self.created, now: Self.at(days: 364.99)) == .expiringSoon(daysLeft: 1))
    }

    @Test func expiredAfterAYear() {
        #expect(TokenHealth.evaluate(createdAt: Self.created, now: Self.at(days: 365)) == .expired)
        #expect(TokenHealth.evaluate(createdAt: Self.created, now: Self.at(days: 800)) == .expired)
    }

    @Test func clockBehindCreationIsOK() {
        #expect(TokenHealth.evaluate(createdAt: Self.created, now: Self.at(days: -3)) == .ok)
    }

    @Test func credentialOverload() {
        let credential = ClaudeCredential(token: "test-token", createdAt: Self.created)
        #expect(TokenHealth.evaluate(credential, now: Self.at(days: 360)) == .expiringSoon(daysLeft: 5))
    }

    @Test func daysLeft() {
        #expect(TokenHealth.daysLeft(createdAt: Self.created, now: Self.created) == 365)
        #expect(TokenHealth.daysLeft(createdAt: Self.created, now: Self.at(days: 364.5)) == 1)
        #expect(TokenHealth.daysLeft(createdAt: Self.created, now: Self.at(days: 366)) == 0)
    }

    @Test func nextChange() {
        #expect(TokenHealth.nextChange(createdAt: Self.created, now: Self.at(days: 10)) == Self.at(days: 335))
        #expect(TokenHealth.nextChange(createdAt: Self.created, now: Self.at(days: 340.25)) == Self.at(days: 341))
        #expect(TokenHealth.nextChange(createdAt: Self.created, now: Self.at(days: 341)) == Self.at(days: 342))
        #expect(TokenHealth.nextChange(createdAt: Self.created, now: Self.at(days: 365)) == nil)
    }

    @Test func daysPhrase() {
        #expect(TokenHealth.daysPhrase(12) == "in 12 days")
        #expect(TokenHealth.daysPhrase(1) == "within a day")
    }
}

@Suite struct ConnectionStateTests {
    static let created = TokenHealthTests.created
    static let credential = ClaudeCredential(token: "test-token", createdAt: created)

    @Test func resolve() {
        let now = TokenHealthTests.at(days: 10)
        #expect(ConnectionState.resolve(isInstalled: false, credential: Self.credential, authFailure: nil, now: now) == .notInstalled)
        #expect(ConnectionState.resolve(isInstalled: true, credential: nil, authFailure: nil, now: now) == .notConnected)
        #expect(ConnectionState.resolve(isInstalled: true, credential: Self.credential, authFailure: nil, now: now)
            == .connected(createdAt: Self.created, health: .ok))
        #expect(ConnectionState.resolve(isInstalled: true, credential: Self.credential, authFailure: "401", now: now)
            == .needsReconnect(reason: .authFailed(message: "401")))
        #expect(ConnectionState.resolve(isInstalled: true, credential: Self.credential, authFailure: nil, now: TokenHealthTests.at(days: 400))
            == .needsReconnect(reason: .expired))
        #expect(ConnectionState.resolve(isInstalled: true, credential: Self.credential, authFailure: nil, now: TokenHealthTests.at(days: 360))
            == .connected(createdAt: Self.created, health: .expiringSoon(daysLeft: 5)))
    }

    @Test func canCleanAndAttention() {
        let ok = ConnectionState.connected(createdAt: Self.created, health: .ok)
        let soon = ConnectionState.connected(createdAt: Self.created, health: .expiringSoon(daysLeft: 3))
        let expired = ConnectionState.needsReconnect(reason: .expired)
        #expect(ok.canClean && soon.canClean)
        #expect(!expired.canClean && !ConnectionState.notConnected.canClean && !ConnectionState.notInstalled.canClean)
        #expect(!ConnectionState.checking.canClean)
        #expect(!ok.needsAttention)
        #expect(soon.needsAttention && expired.needsAttention)
        #expect(!ConnectionState.notConnected.needsAttention)
    }

    @Test func copy() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(ConnectionState.formatDate(TokenHealth.expiryDate(createdAt: Self.created), timeZone: utc) == "10 November 2027")

        let soon = ConnectionState.connected(createdAt: Self.created, health: .expiringSoon(daysLeft: 3))
        #expect(soon.title == "Connected · token expires in 3 days")
        #expect(soon.actionTitle == "Reconnect…")
        #expect(soon.menuMessage == "Claude token expires in 3 days: Reconnect…")
        #expect(ConnectionState.connected(createdAt: Self.created, health: .ok).actionTitle == nil)
        #expect(ConnectionState.notInstalled.actionTitle == "Install Claude Code…")
        #expect(ConnectionState.notConnected.actionTitle == "Connect…")
        #expect(ConnectionState.notConnected.rawFallbackHint == "Connect Claude to tidy")
        #expect(ConnectionState.needsReconnect(reason: .expired).title == "Token expired")

        let failed = ConnectionState.needsReconnect(reason: .authFailed(message: "OAuth token revoked"))
        #expect(failed.detail.contains("“OAuth token revoked”"))
        #expect(!ConnectionState.needsReconnect(reason: .authFailed(message: " ")).detail.contains("said"))
    }

    @Test func everyStateHasCopy() {
        let states: [ConnectionState] = [
            .checking, .notInstalled, .notConnected, .connected(createdAt: Self.created, health: .ok),
            .connected(createdAt: Self.created, health: .expiringSoon(daysLeft: 9)),
            .connected(createdAt: Self.created, health: .expired),
            .needsReconnect(reason: .expired), .needsReconnect(reason: .authFailed(message: "x")),
        ]
        for s in states {
            #expect(!s.title.isEmpty)
            #expect(!s.detail.isEmpty)
            // British spelling in user-facing copy.
            for american in ["authorize", "authorization", "color", "canceled", "license"] {
                #expect(!(s.title + s.detail).lowercased().contains(american))
            }
        }
    }
}

@Suite struct ClaudeTokenFormatTests {
    @Test func acceptsARealShapedToken() throws {
        #expect(try ClaudeTokenFormat.validate(SetupTokenSamples.token) == SetupTokenSamples.token)
        #expect(ClaudeTokenFormat.isPlausibleToken(SetupTokenSamples.token))
    }

    @Test func cleansUpWhatPeoplePaste() throws {
        let t = SetupTokenSamples.token
        for pasted in ["  \(t)\n", "export CLAUDE_CODE_OAUTH_TOKEN=\(t)", "CLAUDE_CODE_OAUTH_TOKEN=\"\(t)\"",
                       "'\(t)'", "“\(t)”", "\(t.prefix(50))\n  \(t.dropFirst(50))", "export CLAUDE_CODE_OAUTH_TOKEN='\(t)';",
                       "set CLAUDE_CODE_OAUTH_TOKEN=\(t)"] {
            #expect(try ClaudeTokenFormat.validate(pasted) == t, "\(pasted)")
        }
    }

    @Test func refusals() {
        func error(_ s: String) -> TokenValidationError? {
            do { _ = try ClaudeTokenFormat.validate(s); return nil } catch { return error }
        }
        #expect(error("") == .empty)
        #expect(error("   \n") == .empty)
        #expect(error("sk-ant-api03-" + String(repeating: "a", count: 90)) == .apiKey)
        #expect(error("ghp_" + String(repeating: "a", count: 40)) == .wrongPrefix)
        #expect(error("sk-ant-oat01-abc!def" + String(repeating: "a", count: 40)) == .invalidCharacters)
        #expect(error("sk-ant-oat01-abc") == .tooShort)
        #expect(error("sk-ant-oat01-" + String(repeating: "a", count: 600)) == .tooLong)
    }

    @Test func messagesAreBritishAndNeverOfferAnAPIKey() {
        let all: [TokenValidationError] = [.empty, .apiKey, .wrongPrefix, .invalidCharacters, .tooShort, .tooLong]
        for e in all {
            #expect(!e.message.isEmpty)
            #expect(!e.message.lowercased().contains("authoriz"))
        }
        #expect(TokenValidationError.apiKey.message.contains("subscription"))
    }
}

@Suite struct ClaudeSetupCommandTests {
    @Test func cleanEnvironment() {
        let claude = URL(fileURLWithPath: "/Users/patrick/.local/bin/claude")
        let env = ClaudeSetupCommand.environment(claudeExecutable: claude, home: "/Users/patrick", user: "patrick",
                                                 lang: nil, tmpDir: "/var/folders/x/T/",
                                                 extra: ["ANTHROPIC_API_KEY": "nope", "CLAUDE_CODE_OAUTH_TOKEN": "nope", "FOO": "bar"])
        #expect(env["HOME"] == "/Users/patrick")
        #expect(env["USER"] == "patrick")
        #expect(env["LANG"] == "en_GB.UTF-8")
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["PATH"] == "/Users/patrick/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(env["TMPDIR"] == "/var/folders/x/T/")
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(env["FOO"] == "bar")
        #expect(ClaudeSetupCommand.arguments == ["setup-token"])
    }

    @Test func pathHasNoDuplicates() {
        #expect(ClaudeSetupCommand.path(including: "/usr/bin") == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func keepsTheUsersLanguage() {
        let env = ClaudeSetupCommand.environment(claudeExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                                                 home: "/h", user: "u", lang: "fr_FR.UTF-8")
        #expect(env["LANG"] == "fr_FR.UTF-8")
        #expect(env["TMPDIR"] == nil)
    }
}

@Suite struct TerminalScriptTests {
    @Test func shellQuote() {
        #expect(TerminalScript.shellQuote("/usr/local/bin/claude") == "/usr/local/bin/claude")
        #expect(TerminalScript.shellQuote("/Users/Pat Smith/bin/claude") == "'/Users/Pat Smith/bin/claude'")
        #expect(TerminalScript.shellQuote("it's") == "'it'\\''s'")
        #expect(TerminalScript.shellQuote("") == "''")
        #expect(TerminalScript.shellQuote("$(rm -rf ~)") == "'$(rm -rf ~)'")
    }

    @Test func installScriptRunsTheOfficialInstallerUnmodified() {
        let script = TerminalScript.installClaude()
        #expect(script.hasPrefix("#!/bin/bash\n"))
        #expect(script.contains("/bin/bash -c 'curl -fsSL https://claude.ai/install.sh | bash'\n"))
        #expect(script.contains("rm -f -- \"$0\""))
    }

    @Test func cancellableInstallerKeepsTheOfficialCommand() {
        #expect(TerminalScript.cancellableInstallScript.contains("\ncurl -fsSL https://claude.ai/install.sh | bash &\n"))
    }

    /// SIGTERM to the outer bash must take the whole pipeline (and its children) down with it.
    @Test func cancellingStopsTheWholePipeline() async throws {
        #if os(Linux) || os(macOS)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/pgrep") else { return }
        let marker = "devshout-test-\(UUID().uuidString.prefix(8))"
        let script = TerminalScript.cancellable("bash -c 'sleep 61; : \(marker)' | bash -c 'sleep 62; : \(marker)'")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        try Self.runWithSignalsUnblocked(p)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(Self.processes(matching: marker) >= 2)
        p.terminate()
        p.waitUntilExit()
        #expect(p.terminationStatus == 143)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(Self.processes(matching: marker) == 0)
        #endif
    }

    /// The test runner's threads block most signals, and swift-corelibs-foundation passes that mask on to the
    /// child, which would then never see SIGTERM. (The app starts the installer from the main thread.)
    static func runWithSignalsUnblocked(_ p: Process) throws {
        #if canImport(Glibc)
        var empty = sigset_t()
        var old = sigset_t()
        sigemptyset(&empty)
        pthread_sigmask(SIG_SETMASK, &empty, &old)
        defer { pthread_sigmask(SIG_SETMASK, &old, nil) }
        #endif
        try p.run()
    }

    static func processes(matching pattern: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", pattern]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(separator: "\n").count
    }

    @Test func setupTokenScriptQuotesThePath() {
        let script = TerminalScript.setupToken(claudeExecutable: URL(fileURLWithPath: "/Users/Pat Smith/.local/bin/claude"))
        #expect(script.contains("'/Users/Pat Smith/.local/bin/claude' setup-token\n"))
        #expect(script.contains("Paste a token"))
    }

    @Test func scriptsAreValidBash() throws {
        #if os(Linux) || os(macOS)
        let bash = URL(fileURLWithPath: "/bin/bash")
        guard FileManager.default.isExecutableFile(atPath: bash.path) else { return }
        for script in [TerminalScript.installClaude(), TerminalScript.setupToken(claudeExecutable: URL(fileURLWithPath: "/x y/claude")),
                       TerminalScript.cancellableInstallScript] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("devshout-\(UUID().uuidString).command")
            try script.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let p = Process()
            p.executableURL = bash
            p.arguments = ["-n", file.path]  // syntax check only: runs nothing
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)
        }
        #endif
    }
}

@Suite struct ClaudeInstallationTests {
    @Test func summary() {
        let i = ClaudeInstallation(url: URL(fileURLWithPath: "/Users/patrick/.local/bin/claude"), version: ClaudeVersion(2, 1, 322))
        #expect(i.summary(homeDirectory: "/Users/patrick") == "Claude Code 2.1.322 (~/.local/bin/claude)")
        #expect(ClaudeInstallation(url: URL(fileURLWithPath: "/opt/homebrew/bin/claude"), version: ClaudeVersion(2, 1, 0))
            .summary(homeDirectory: "/Users/patrick") == "Claude Code 2.1.0 (/opt/homebrew/bin/claude)")
    }

    @Test func authFailureBelongsToOneToken() throws {
        let old = ClaudeCredential(token: "a", createdAt: Date(timeIntervalSince1970: 100))
        let new = ClaudeCredential(token: "b", createdAt: Date(timeIntervalSince1970: 200))
        let failure = ClaudeAuthFailure(credentialCreatedAt: old.createdAt, message: "401")
        #expect(failure.message(for: old) == "401")
        #expect(failure.message(for: new) == nil)
        #expect(failure.message(for: nil) == nil)
        let round = try JSONDecoder().decode(ClaudeAuthFailure.self, from: JSONEncoder().encode(failure))
        #expect(round == failure)
    }
}
