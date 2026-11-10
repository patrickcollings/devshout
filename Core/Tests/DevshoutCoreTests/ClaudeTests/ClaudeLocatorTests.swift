import Foundation
import Testing
@testable import DevshoutCore

@Suite struct ClaudeLocatorTests {
    let home = "/Users/patrick"

    /// A runner that answers `--version` with `version` and the login shell with `shellAnswer`.
    func runner(version: String = "2.1.300 (Claude Code)", shellAnswer: String? = nil) -> StubRunner {
        StubRunner { request in
            if request.arguments == ["--version"] { return StubRunner.result(stdout: version + "\n") }
            if request.arguments.first == "-l" {
                guard let shellAnswer else { return StubRunner.result(exitCode: 1) }
                return StubRunner.result(stdout: shellAnswer)
            }
            return StubRunner.result(exitCode: 127)
        }
    }

    func locator(_ fs: FakeFileSystem, runner: StubRunner? = nil, override: URL? = nil,
                 shell: String? = "/bin/zsh") -> ClaudeLocator {
        ClaudeLocator(fileSystem: fs, runner: runner ?? self.runner(), userOverride: override, shell: shell)
    }

    @Test func searchOrder() {
        let fs = FakeFileSystem(directories: ["\(home)/.nvm/versions/node": ["v18.20.0", "v22.11.0", "v20.9.0"]])
        let paths = locator(fs, override: URL(fileURLWithPath: "/custom/claude")).candidatePaths()
        #expect(paths == [
            "/custom/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.nvm/versions/node/v22.11.0/bin/claude",
            "\(home)/.nvm/versions/node/v20.9.0/bin/claude",
            "\(home)/.nvm/versions/node/v18.20.0/bin/claude",
            "\(home)/.npm-global/bin/claude",
        ])
    }

    @Test func userOverrideWins() async throws {
        let fs = FakeFileSystem(executables: ["/custom/claude", "\(home)/.local/bin/claude"])
        let found = try await locator(fs, override: URL(fileURLWithPath: "/custom/claude")).locate()
        #expect(found == ClaudeInstallation(url: URL(fileURLWithPath: "/custom/claude"), version: ClaudeVersion(2, 1, 300)))
    }

    @Test func missingOverrideFallsBackToTheSearch() async throws {
        let fs = FakeFileSystem(executables: ["/opt/homebrew/bin/claude"])
        let found = try await locator(fs, override: URL(fileURLWithPath: "/gone/claude")).locate()
        #expect(found.url.path == "/opt/homebrew/bin/claude")
    }

    @Test func nativeInstallBeatsHomebrew() async throws {
        let fs = FakeFileSystem(executables: ["/opt/homebrew/bin/claude", "\(home)/.local/bin/claude"])
        let found = try await locator(fs).locate()
        #expect(found.url.path == "\(home)/.local/bin/claude")
    }

    @Test func newestNvmNode() async throws {
        let fs = FakeFileSystem(
            executables: ["\(home)/.nvm/versions/node/v20.9.0/bin/claude", "\(home)/.nvm/versions/node/v18.1.0/bin/claude"],
            directories: ["\(home)/.nvm/versions/node": ["v18.1.0", "v20.9.0"]])
        let found = try await locator(fs).locate()
        #expect(found.url.path == "\(home)/.nvm/versions/node/v20.9.0/bin/claude")
    }

    @Test func loginShellIsTheLastResort() async throws {
        let fs = FakeFileSystem(executables: ["/bin/zsh", "/Users/patrick/bin/claude"])
        let stub = runner(shellAnswer: "Welcome to zsh!\n/Users/patrick/bin/claude\n")
        let found = try await locator(fs, runner: stub).locate()
        #expect(found.url.path == "/Users/patrick/bin/claude")
        let shellRequest = try #require(stub.requests.first { $0.arguments.first == "-l" })
        #expect(shellRequest.executable.path == "/bin/zsh")
        #expect(shellRequest.arguments == ["-l", "-c", "command -v claude"])
        #expect(shellRequest.timeout == 3)
        #expect(shellRequest.environment["HOME"] == home)
    }

    @Test func npmGlobalInstallGetsNodeOnItsPath() async throws {
        let claude = "\(home)/.npm-global/bin/claude"
        let fs = FakeFileSystem(executables: [claude, "/opt/homebrew/bin/node"], scripts: [claude])
        let stub = runner()
        let found = try await locator(fs, runner: stub).locate()
        #expect(found.url.path == claude)
        #expect(found.extraPath == ["/opt/homebrew/bin"])
        let versionRequest = try #require(stub.requests.first { $0.arguments == ["--version"] })
        #expect(versionRequest.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin:\(home)/.npm-global/bin:/opt/homebrew/bin")
    }

    @Test func nvmInstallFindsNodeBesideIt() async throws {
        let bin = "\(home)/.nvm/versions/node/v22.1.0/bin"
        let fs = FakeFileSystem(executables: ["\(bin)/claude", "\(bin)/node", "/opt/homebrew/bin/node"],
                                directories: ["\(home)/.nvm/versions/node": ["v22.1.0"]],
                                scripts: ["\(bin)/claude"])
        let found = try await locator(fs).locate()
        #expect(found.extraPath == [])
    }

    @Test func nodeFromTheLoginShell() async throws {
        let claude = "\(home)/.claude/local/claude"
        let fs = FakeFileSystem(executables: [claude, "/bin/zsh", "\(home)/.asdf/shims/node"], scripts: [claude])
        let stub = StubRunner { request in
            if request.arguments == ["--version"] { return StubRunner.result(stdout: "2.1.300 (Claude Code)\n") }
            if request.arguments == ["-l", "-c", "command -v node"] {
                return StubRunner.result(stdout: "\(home)/.asdf/shims/node\n")
            }
            return StubRunner.result(exitCode: 1)
        }
        let found = try await locator(fs, runner: stub).locate()
        #expect(found.extraPath == ["\(home)/.asdf/shims"])
    }

    @Test func nativeBinaryNeedsNoExtraPath() async throws {
        let fs = FakeFileSystem(executables: ["\(home)/.local/bin/claude", "/opt/homebrew/bin/node"])
        #expect(try await locator(fs).locate().extraPath == [])
    }

    @Test func aCandidateThatDoesNotRunIsSkipped() async throws {
        let broken = "\(home)/.local/bin/claude"
        let fs = FakeFileSystem(executables: [broken, "/opt/homebrew/bin/claude"])
        let stub = StubRunner { request in
            if request.executable.path == broken { return StubRunner.result(stderr: "env: node: No such file", exitCode: 127) }
            return StubRunner.result(stdout: "2.1.5 (Claude Code)\n")
        }
        let found = try await locator(fs, runner: stub).locate()
        #expect(found.url.path == "/opt/homebrew/bin/claude")
        #expect(found.version == ClaudeVersion(2, 1, 5))
    }

    @Test func loginShellAnswerMustBeExecutable() async {
        let fs = FakeFileSystem(executables: ["/bin/zsh"])
        let stub = runner(shellAnswer: "/nowhere/claude\n")
        await #expect(throws: ClaudeLocatorError.self) { try await locator(fs, runner: stub).locate() }
    }

    @Test func shellAliasOutputIsIgnored() async {
        let fs = FakeFileSystem(executables: ["/bin/zsh"])
        let stub = runner(shellAnswer: "claude: aliased to npx claude\n")
        #expect(await locator(fs, runner: stub).findExecutable() == nil)
    }

    @Test func notFoundListsWhereItLooked() async {
        let fs = FakeFileSystem()
        do {
            _ = try await locator(fs, shell: "/bin/zsh").locate()
            Issue.record("expected notFound")
        } catch ClaudeLocatorError.notFound(let searched) {
            #expect(searched.first == "\(home)/.local/bin/claude")
            #expect(searched.last == "/bin/zsh -l -c 'command -v claude'")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func tooOld() async {
        let fs = FakeFileSystem(executables: ["\(home)/.local/bin/claude"])
        do {
            _ = try await locator(fs, runner: runner(version: "2.0.77 (Claude Code)")).locate()
            Issue.record("expected tooOld")
        } catch let error as ClaudeLocatorError {
            #expect(error == .tooOld(path: "\(home)/.local/bin/claude", found: ClaudeVersion(2, 0, 77),
                                     minimum: ClaudeLocator.minimumVersion))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func unreadableVersion() async {
        let fs = FakeFileSystem(executables: ["\(home)/.local/bin/claude"])
        await #expect(throws: ClaudeLocatorError.versionUnreadable(path: "\(home)/.local/bin/claude",
                                                                   output: "command not found\n")) {
            _ = try await locator(fs, runner: runner(version: "command not found")).locate()
        }
    }

    @Test func versionRequestIsMinimal() async throws {
        let fs = FakeFileSystem(executables: ["\(home)/.local/bin/claude"])
        let stub = runner()
        _ = try await locator(fs, runner: stub).locate()
        let request = try #require(stub.requests.first)
        #expect(request.arguments == ["--version"])
        #expect(request.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin:\(home)/.local/bin")
        #expect(request.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(request.environment["DISABLE_AUTOUPDATER"] == "1")
    }

    @Test(arguments: [
        ("2.1.300 (Claude Code)", ClaudeVersion(2, 1, 300)),
        ("claude 2.1.0", ClaudeVersion(2, 1, 0)),
        ("v10.20.30-beta", ClaudeVersion(10, 20, 30)),
    ])
    func parsesVersions(text: String, version: ClaudeVersion) {
        #expect(ClaudeVersion(parsing: text) == version)
    }

    @Test func versionComparison() {
        #expect(ClaudeVersion(2, 1, 0) < ClaudeVersion(2, 1, 10))
        #expect(ClaudeVersion(2, 1, 10) < ClaudeVersion(2, 2, 0))
        #expect(ClaudeVersion(1, 99, 99) < ClaudeVersion(2, 0, 0))
        #expect(ClaudeVersion(parsing: "unknown") == nil)
        #expect(ClaudeLocator.minimumVersion == ClaudeVersion(2, 1, 0))
        #expect(ClaudeVersion(2, 1, 300).description == "2.1.300")
    }

    @Test func cacheSearchesOnceUntilInvalidated() async throws {
        let fs = FakeFileSystem(executables: ["\(home)/.local/bin/claude"])
        let stub = runner()
        let cache = ClaudeInstallationCache(locator: locator(fs, runner: stub))
        _ = try await cache.installation()
        _ = try await cache.installation()
        #expect(stub.requests.count == 1)
        await cache.invalidate()
        _ = try await cache.installation()
        #expect(stub.requests.count == 2)
    }

    @Test func realLocatorFindsAFakeClaudeOnDisk() async throws {
        let home = try ClaudeTestSupport.temporaryDirectory("home")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        _ = try ClaudeTestSupport.fakeClaude(mode: "ok-echo", extraEnvironment: ["FAKE_CLAUDE_VERSION": "2.1.42"],
                                             in: bin, settingsDirectory: home.appendingPathComponent(".claude"))
        let locator = ClaudeLocator(fileSystem: LocalFileSystem(homeDirectory: home), shell: nil)
        let found = try await locator.locate()
        #expect(found.url.path == bin.appendingPathComponent("claude").path)
        #expect(found.version == ClaudeVersion(2, 1, 42))
        #expect(found.meetsMinimum)
    }
}
