import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
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

    /// Writes an executable `/bin/sh` script and returns its URL.
    @discardableResult
    static func writeScript(_ body: String, named name: String, in directory: URL) throws -> URL {
        // Written with O_CLOEXEC: a child spawned by a parallel test at the same moment must not inherit the
        // descriptor, or running the script fails with ETXTBSY ("text file busy") for as long as that child lives.
        let url = directory.appendingPathComponent(name)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o755)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let bytes = Array(("#!/bin/sh\n" + body + "\n").utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == bytes.count else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// A `claude` in a fresh folder that runs `scripts/fake-claude.sh` in the given mode. devshout gives claude a
    /// clean environment, so the mode has to be baked into the wrapper.
    static func fakeClaude(mode: String, extraEnvironment: [String: String] = [:],
                           in directory: URL) throws -> URL {
        var exports = "FAKE_CLAUDE_MODE='\(mode)'; export FAKE_CLAUDE_MODE\n"
        for (key, value) in extraEnvironment.sorted(by: { $0.key < $1.key }) {
            exports += "\(key)='\(value)'; export \(key)\n"
        }
        return try writeScript(exports + "exec /bin/sh '\(fakeClaudeScript.path)' \"$@\"",
                               named: "claude", in: directory)
    }

    static let credential = ClaudeCredential(token: "sk-ant-oat01-test-token",
                                             createdAt: Date(timeIntervalSince1970: 1_790_000_000))

    static let host = ClaudeHostEnvironment(home: "/Users/patrick", user: "patrick", lang: "en_GB.UTF-8",
                                            tmpDir: "/var/folders/xy/T/")
}

/// A file system made of a set of executable paths and directory listings.
struct FakeFileSystem: FileSystem {
    var homeDirectory: URL = URL(fileURLWithPath: "/Users/patrick")
    var executables: Set<String> = []
    var directories: [String: [String]] = [:]

    func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }
    func contentsOfDirectory(atPath path: String) -> [String] { directories[path] ?? [] }
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
