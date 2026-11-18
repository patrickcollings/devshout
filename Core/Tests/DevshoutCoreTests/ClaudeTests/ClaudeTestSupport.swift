import Foundation
import Testing
@testable import DevshoutCore

/// Helpers shared by the Claude tests.
enum ClaudeTestSupport {
    /// The repository root, found from this file's path (tests run from the source tree on Linux and macOS).
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ClaudeTests
        .deletingLastPathComponent()   // DevshoutCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Core
        .deletingLastPathComponent()   // repo

    static let fakeClaudeScript = repoRoot.appendingPathComponent("scripts/fake-claude.sh")

    /// Fixtures as bundled with the test target.
    static func fixtureURL(_ name: String) -> URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("claude")
            .appendingPathComponent(name)
    }

    static func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixtureURL(name), encoding: .utf8)
    }

    static func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name))
    }

    /// The fixture folder in the source tree, for regenerating golden files with `UPDATE_GOLDEN=1`.
    static let sourceFixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/claude")

    /// Compares `actual` with a golden file. With `UPDATE_GOLDEN=1` in the environment, rewrites it instead.
    static func expectGolden(_ actual: String, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1" {
            try actual.write(to: sourceFixtures.appendingPathComponent(name), atomically: true, encoding: .utf8)
            return
        }
        let expected = try fixture(name)
        #expect(actual == expected, "golden file \(name) differs; run with UPDATE_GOLDEN=1 to rewrite it",
                sourceLocation: sourceLocation)
    }

    static func temporaryDirectory(_ label: String = "claude-tests") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devshout-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A `claude` in `directory`: a symlink to `scripts/fake-claude.sh`. devshout gives claude a clean environment,
    /// so the mode and other settings go in `fake-claude.env` in `settingsDirectory`, which the script reads from
    /// `$CLAUDE_CONFIG_DIR` (clean-ups) or `$HOME/.claude` (`--version`).
    ///
    /// Nothing executable is written here: running a file another thread has just written can fail with ETXTBSY
    /// ("text file busy") while a child spawned by a parallel test still holds the descriptor.
    static func fakeClaude(mode: String, extraEnvironment: [String: String] = [:],
                           in directory: URL, settingsDirectory: URL) throws -> URL {
        var settings = extraEnvironment
        settings["FAKE_CLAUDE_MODE"] = mode
        var lines = ""
        for (key, value) in settings.sorted(by: { $0.key < $1.key }) {
            lines += "\(key)='\(value)'; export \(key)\n"
        }
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        try lines.write(to: settingsDirectory.appendingPathComponent("fake-claude.env"), atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fakeClaudeScript)
        return link
    }

    static let credential = ClaudeCredential(token: "fake-token-for-tests",
                                             createdAt: Date(timeIntervalSince1970: 1_790_000_000))

    static let host = ClaudeHostEnvironment(home: "/Users/sam", user: "sam", lang: "en_GB.UTF-8",
                                            tmpDir: "/var/folders/xy/T/")
}

/// A file system made of a set of executable paths and directory listings.
struct FakeFileSystem: FileSystem {
    var homeDirectory: URL = URL(fileURLWithPath: "/Users/sam")
    var executables: Set<String> = []
    var directories: [String: [String]] = [:]
    /// Executables that are scripts (`#!…`); the others read as a native binary.
    var scripts: Set<String> = []

    func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }
    func contentsOfDirectory(atPath path: String) -> [String] { directories[path] ?? [] }
    func readPrefix(atPath path: String, maxLength: Int) -> Data? {
        guard executables.contains(path) else { return nil }
        let bytes = scripts.contains(path) ? Data("#!/usr/bin/env node\n".utf8) : Data([0xCF, 0xFA, 0xED, 0xFE])
        return bytes.prefix(maxLength)
    }
}

/// Runs processes for real and keeps each result, so a test can look at how long the *process* ran
/// (`ProcessResult.elapsed`, measured on the runner's own thread) rather than time the whole call with a stopwatch.
/// A stopwatch around an `await` also counts the wait for a free task thread, which on a loaded 2-core CI runner
/// has been over 40 s.
final class RecordingRunner: ProcessRunner, @unchecked Sendable {
    private let inner: any ProcessRunner
    private let lock = NSLock()
    private var _results: [ProcessResult] = []

    init(_ inner: any ProcessRunner) { self.inner = inner }

    var results: [ProcessResult] { lock.withLock { _results } }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let result = try await inner.run(request)
        lock.withLock { _results.append(result) }
        return result
    }
}

/// A ProcessRunner that answers from a closure and records every request.
final class StubRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ProcessRequest] = []
    private let handler: @Sendable (ProcessRequest) throws -> ProcessResult

    init(_ handler: @escaping @Sendable (ProcessRequest) throws -> ProcessResult) {
        self.handler = handler
    }

    var requests: [ProcessRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        record(request)
        return try handler(request)
    }

    private func record(_ request: ProcessRequest) {
        lock.withLock { _requests.append(request) }
    }

    static func result(stdout: String = "", stderr: String = "", exitCode: Int32 = 0,
                       timedOut: Bool = false, elapsed: TimeInterval = 0.1) -> ProcessResult {
        ProcessResult(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8),
                      timedOut: timedOut, elapsed: elapsed)
    }
}
