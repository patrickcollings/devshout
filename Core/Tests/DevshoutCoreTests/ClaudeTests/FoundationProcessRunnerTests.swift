import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Testing
@testable import DevshoutCore

@Suite struct FoundationProcessRunnerTests {
    let sh = URL(fileURLWithPath: "/bin/sh")
    let runner = FoundationProcessRunner(killGracePeriod: 0.5, outputDrainTimeout: 0.5)

    func shell(_ script: String, environment: [String: String] = ["PATH": "/usr/bin:/bin"],
               cwd: URL? = nil, stdin: Data? = nil, timeout: TimeInterval? = nil) -> ProcessRequest {
        ProcessRequest(executable: sh, arguments: ["-c", script], environment: environment,
                       currentDirectory: cwd, stdin: stdin, timeout: timeout)
    }

    @Test func capturesStdoutStderrAndExitCode() async throws {
        let result = try await runner.run(shell("echo out; echo err >&2; exit 3"))
        #expect(result.stdoutString == "out\n")
        #expect(result.stderrString == "err\n")
        #expect(result.exitCode == 3)
        #expect(!result.timedOut)
        #expect(result.elapsed >= 0 && result.elapsed < 5)
    }

    @Test func environmentIsExactlyWhatWasGiven() async throws {
        let result = try await runner.run(ProcessRequest(
            executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [],
            environment: ["ONLY_THIS": "yes", "AND": "that"]))
        let lines = Set(result.stdoutString.split(separator: "\n").map(String.init))
        #expect(lines == ["ONLY_THIS=yes", "AND=that"])
    }

    @Test func runsInTheGivenDirectory() async throws {
        let dir = try ClaudeTestSupport.temporaryDirectory("cwd")
        let result = try await runner.run(shell("pwd -P", cwd: dir))
        // realpath, not URL.resolvingSymlinksInPath: on macOS that turns /private/var back into /var.
        let expected = try #require(realpath(dir.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        #expect(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
    }

    @Test func passesStdin() async throws {
        let result = try await runner.run(shell("cat", stdin: Data("hello\nworld".utf8)))
        #expect(result.stdoutString == "hello\nworld")
    }

    @Test func noStdinMeansEndOfFileStraightAway() async throws {
        let result = try await runner.run(shell("cat; echo done", timeout: 5))
        #expect(result.stdoutString == "done\n")
        #expect(!result.timedOut)
    }

    /// Several MB through stdin, stdout and stderr at once: would deadlock if any pipe were read or written in turn.
    @Test func largeStreamsDoNotDeadlock() async throws {
        let size = 3 * 1024 * 1024
        let input = Data(repeating: UInt8(ascii: "x"), count: size)
        let script = "cat; head -c \(size) /dev/zero | tr '\\0' 'e' >&2"
        let result = try await runner.run(shell(script, stdin: input, timeout: 30))
        #expect(!result.timedOut)
        #expect(result.stdout.count == size)
        #expect(result.stderr.count == size)
    }

    @Test func childThatIgnoresStdinDoesNotCrashUs() async throws {
        let input = Data(repeating: 65, count: 4 * 1024 * 1024)
        let result = try await runner.run(shell("exit 0", stdin: input, timeout: 10))
        #expect(result.exitCode == 0)
    }

    @Test func timeoutSendsSIGTERM() async throws {
        // The trap proves SIGTERM arrived. (The exit code can't be checked reliably on Linux: Foundation there only
        // sees the exit once every process that inherited its descriptors has gone, and parallel tests spawn many.)
        let script = "trap 'kill $!; echo terminated; exit 0' TERM; sleep 30 & wait"
        let result = try await runner.run(shell(script, timeout: 0.3))
        #expect(result.timedOut)
        #expect(result.stdoutString == "terminated\n")
        #expect(result.elapsed < 5)
    }

    @Test func timeoutReportsTheSignal() async throws {
        let result = try await runner.run(ProcessRequest(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                         arguments: ["30"], environment: [:], timeout: 0.3))
        #expect(result.timedOut)
        #expect([Int32(143), Int32(137)].contains(result.exitCode))
    }

    @Test func timeoutEscalatesToSIGKILL() async throws {
        // The shell ignores SIGTERM, so only SIGKILL stops it.
        let script = "trap '' TERM; echo started; while :; do sleep 0.05; done"
        let result = try await runner.run(shell(script, timeout: 0.3))
        #expect(result.timedOut)
        #expect(result.exitCode == 128 + 9)
        #expect(result.stdoutString.hasPrefix("started\n"))
        #expect(result.elapsed < 5)
    }

    @Test func outputBeforeTheTimeoutIsKept() async throws {
        let result = try await runner.run(shell("echo partial; exec sleep 30", timeout: 0.3))
        #expect(result.timedOut)
        #expect(result.stdoutString == "partial\n")
    }

    @Test func grandchildHoldingThePipeDoesNotBlock() async throws {
        // `sleep` inherits stdout and outlives the shell; we stop waiting for end-of-file after the drain timeout.
        let result = try await runner.run(shell("echo hi; sleep 1 & exit 0", timeout: 10))
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "hi\n")
        #expect(!result.timedOut)
        #if os(macOS)
        // On Linux, Foundation only reports the shell's exit once the grandchild has gone too.
        #expect(result.elapsed < 0.9)
        #endif
    }

    @Test func timeoutDoesNotWaitForAnOrphanedGrandchild() async throws {
        // The shell dies on SIGTERM but its `sleep` lives on, holding the pipes.
        let result = try await runner.run(shell("echo started; sleep 4; echo never", timeout: 0.3))
        #expect(result.timedOut)
        #expect(result.stdoutString == "started\n")
        #expect(result.elapsed < 3.5)
    }

    @Test func missingExecutableThrows() async {
        let request = ProcessRequest(executable: URL(fileURLWithPath: "/nonexistent/claude"), arguments: [],
                                     environment: [:])
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await runner.run(request)
        }
    }

    @Test func cancellationStopsTheChild() async throws {
        let runner = self.runner
        let request = shell("exec sleep 30")
        let task = Task { try await runner.run(request) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(Date().timeIntervalSince(start) < 25)
    }
}
