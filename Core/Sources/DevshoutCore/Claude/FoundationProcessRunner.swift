import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Why a process could not be run at all (as opposed to running and failing).
public enum ProcessRunnerError: Error, Sendable, Hashable {
    /// `Process.run()` refused: the executable is missing, not executable, or the working folder doesn't exist.
    case launchFailed(executable: String, message: String)
}

/// `ProcessRunner` built on `Foundation.Process`. Works on Linux and macOS.
///
/// - The child gets exactly `request.environment` (nothing is inherited) and `request.currentDirectory`.
/// - stdin is written on its own thread, and stdout and stderr are drained on two more, so a child that writes a lot
///   before reading its input (or the other way round) can't deadlock on a full pipe.
/// - On timeout the child gets SIGTERM, then SIGKILL after `killGracePeriod`.
/// - Cancelling the calling task stops the child the same way and throws `CancellationError`.
/// - If a grandchild keeps the output pipes open after the child exits, the runner waits at most
///   `outputDrainTimeout` for end-of-file and returns what it has read so far.
public struct FoundationProcessRunner: ProcessRunner {
    public var killGracePeriod: TimeInterval
    public var outputDrainTimeout: TimeInterval

    public init(killGracePeriod: TimeInterval = 2, outputDrainTimeout: TimeInterval = 1) {
        self.killGracePeriod = killGracePeriod
        self.outputDrainTimeout = outputDrainTimeout
        Self.ignoreSIGPIPE
    }

    /// Writing to a child that has already exited must give EPIPE, not kill devshout.
    private static let ignoreSIGPIPE: Void = {
        _ = signal(SIGPIPE, SIG_IGN)
    }()

    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let killGracePeriod = self.killGracePeriod
        let outputDrainTimeout = self.outputDrainTimeout
        let control = ProcessControl(killGracePeriod: killGracePeriod)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                // Process start-up and the blocking reads happen off the cooperative pool.
                Thread.detachNewThread {
                    do {
                        let result = try Self.runBlocking(request, control: control, killGracePeriod: killGracePeriod,
                                                          outputDrainTimeout: outputDrainTimeout)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            control.cancel()
        }
        if control.isCancelled { throw CancellationError() }
        return result
    }

    // MARK: - Blocking implementation

    private static func runBlocking(_ request: ProcessRequest, control: ProcessControl, killGracePeriod: TimeInterval,
                                    outputDrainTimeout: TimeInterval) throws -> ProcessResult {
        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.environment = request.environment
        if let cwd = request.currentDirectory {
            process.currentDirectoryURL = cwd
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe: Pipe? = request.stdin == nil ? nil : Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        // Keep these pipes out of any other child spawned at the same moment (the child's own copies on 0, 1 and 2
        // are made with dup2, which clears the flag).
        for pipe in [stdoutPipe, stderrPipe, stdinPipe].compactMap({ $0 }) {
            setCloseOnExec(pipe.fileHandleForReading.fileDescriptor)
            setCloseOnExec(pipe.fileHandleForWriting.fileDescriptor)
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        // The child inherits this thread's signal mask (Foundation on Linux doesn't reset it, and Swift's threads
        // block most signals), so unblock the ones that must be able to stop it.
        unblockTerminationSignals()

        let start = DispatchTime.now()
        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(executable: request.executable.path,
                                                  message: (error as NSError).localizedDescription)
        }
        control.launched(process)

        // Our copies of the child's ends must be closed, or we'd never see end-of-file.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        try? stdinPipe?.fileHandleForReading.close()

        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
        let drained = DispatchGroup()
        drain(stdoutPipe.fileHandleForReading, into: stdoutBuffer, group: drained)
        drain(stderrPipe.fileHandleForReading, into: stderrBuffer, group: drained)

        if let stdinPipe, let data = request.stdin {
            let handle = UncheckedBox(stdinPipe.fileHandleForWriting)
            Thread.detachNewThread {
                writeAll(data, to: handle.value.fileDescriptor)
                try? handle.value.close()
            }
        }

        var timedOut = false
        var didExit = true
        if let timeout = request.timeout {
            if exited.wait(timeout: .now() + max(0, timeout)) == .timedOut {
                timedOut = true
                let pid = process.processIdentifier
                if process.isRunning { kill(pid, SIGTERM) }
                if exited.wait(timeout: .now() + max(0, killGracePeriod)) == .timedOut {
                    if process.isRunning { kill(pid, SIGKILL) }
                    // SIGKILL can't be refused, but on Linux Foundation only reports the exit once every process
                    // sharing its descriptors (grandchildren too) has gone. Don't wait for those.
                    didExit = exited.wait(timeout: .now() + max(0.5, killGracePeriod)) == .success
                }
            }
        } else {
            exited.wait()
        }
        if didExit {
            // `terminationHandler` can run just before `terminationStatus` is final on some platforms.
            process.waitUntilExit()
        }

        _ = drained.wait(timeout: .now() + max(0, outputDrainTimeout))
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        let exitCode: Int32
        if !didExit {
            exitCode = 128 + SIGKILL
        } else {
            exitCode = Self.exitCode(of: process)
        }

        return ProcessResult(exitCode: exitCode, stdout: stdoutBuffer.data, stderr: stderrBuffer.data,
                             timedOut: timedOut, elapsed: elapsed)
    }

    private static func exitCode(of process: Process) -> Int32 {
        switch process.terminationReason {
        case .exit: process.terminationStatus
        // Killed by a signal: report it the way a shell would (128 + signal number).
        case .uncaughtSignal: 128 + process.terminationStatus
        @unknown default: process.terminationStatus
        }
    }

    private static func setCloseOnExec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
    }

    /// Only ever called on the runner's own thread.
    private static func unblockTerminationSignals() {
        var set = sigset_t()
        sigemptyset(&set)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE] { sigaddset(&set, signal) }
        pthread_sigmask(SIG_UNBLOCK, &set, nil)
    }

    /// Reads a pipe to end-of-file on its own thread.
    private static func drain(_ fileHandle: FileHandle, into buffer: OutputBuffer, group: DispatchGroup) {
        group.enter()
        let handle = UncheckedBox(fileHandle)
        Thread.detachNewThread {
            let fd = handle.value.fileDescriptor
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    buffer.append(chunk, count: count)
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            try? handle.value.close()
            group.leave()
        }
    }

    /// Writes everything, retrying on EINTR; gives up quietly when the child has closed its end (EPIPE).
    private static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written > 0 {
                    pointer += written
                    remaining -= written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}

/// Lets task cancellation stop a process that is running on another thread.
private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let killGracePeriod: TimeInterval

    init(killGracePeriod: TimeInterval) {
        self.killGracePeriod = killGracePeriod
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func launched(_ process: Process) {
        lock.lock()
        self.process = process
        let stopNow = cancelled
        lock.unlock()
        if stopNow { stop(process) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process { stop(process) }
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + killGracePeriod) { [self] in
            self.killIfStillRunning()
        }
    }

    private func killIfStillRunning() {
        lock.lock()
        let process = self.process
        lock.unlock()
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

/// Carries a Foundation object that isn't marked `Sendable` on every platform to one other thread, which then
/// owns it.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A thread-safe byte buffer the reader threads append to.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ bytes: [UInt8], count: Int) {
        lock.lock()
        storage.append(contentsOf: bytes[0..<count])
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
