// PseudoTerminal: runs one process attached to a pseudo-terminal, streams what it prints and lets us type into it.
//
// Unsure / unverified on macOS (written and run on Linux only; the logic is the same, the SDK is not):
// - `openpty` comes from <util.h>, which the Darwin module exports (SwiftTerm calls `forkpty` from the same header).
// - Foundation's `Process` on macOS gives the child the slave as fd 0/1/2 but no controlling terminal (no setsid).
//   Claude Code only needs isatty() and tcsetattr() on them, which work without one; checked on Linux with
//   Claude Code 2.1.322 and swift-corelibs-foundation.
// - Reads the master with a DispatchSourceRead (kqueue on macOS, which supports pseudo-terminals; SwiftTerm reads its
//   master with DispatchIO). End-of-file arrives as read() == 0 or EIO once the child side is closed.
// - Assumes Foundation does not close a `FileHandle` passed as standardInput/Output/Error after launching
//   (it only does that for `Pipe`), so the parent closes the slave itself.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class PseudoTerminal: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        /// Bytes the process wrote (stdout and stderr share the terminal).
        case output(Data)
        /// The process ended (exit status, or 128 + signal) and everything it printed has been delivered.
        case exited(Int32)
    }

    public struct Size: Sendable, Equatable {
        public var columns: UInt16
        public var rows: UInt16
        public init(columns: UInt16, rows: UInt16) {
            self.columns = columns
            self.rows = rows
        }
    }

    public enum PTYError: Error, LocalizedError {
        case openFailed(errno: Int32)
        case launchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .openFailed(let code): "Couldn't open a terminal for Claude Code (\(String(cString: strerror(code))))."
            case .launchFailed(let message): message
            }
        }
    }

    /// Output and exit, in order. Finishes after `.exited`.
    public let events: AsyncStream<Event>

    private let continuation: AsyncStream<Event>.Continuation
    private let process = Process()
    private let queue = DispatchQueue(label: "devshout.pseudo-terminal")
    private let lock = NSLock()
    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var readFinished = false
    private var exitStatus: Int32?
    private var finished = false

    /// Starts `executable` attached to a new pseudo-terminal of `size`.
    /// - Parameter environment: the complete environment for the child (nothing is inherited).
    public init(executable: URL, arguments: [String], environment: [String: String],
                currentDirectory: URL? = nil, size: Size) throws {
        var stream: AsyncStream<Event>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { stream = $0 }
        continuation = stream

        var master: Int32 = -1
        var slave: Int32 = -1
        var windowSize = winsize(ws_row: size.rows, ws_col: size.columns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &windowSize) == 0 else {
            let code = errno
            continuation.finish()
            throw PTYError.openFailed(errno: code)
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        masterFD = master

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        // Handlers hold the terminal strongly until the process has exited and reading has ended, so the
        // file descriptors are always closed; the references are dropped then.
        process.terminationHandler = { p in
            self.processDidExit(p)
        }

        startReading()
        do {
            try process.run()
        } catch {
            close(slave)
            readSource?.cancel()  // closes the master
            continuation.finish()
            throw PTYError.launchFailed(error.localizedDescription)
        }
        // The child has its own copies now. Holding ours open would stop the master ever seeing end-of-file.
        close(slave)
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    /// Types into the terminal, as if from the keyboard. Returns false when the terminal has closed.
    @discardableResult
    public func write(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard masterFD >= 0, !readFinished else { return false }
        let fd = masterFD
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            var attempts = 0
            while remaining > 0 {
                #if canImport(Darwin)
                let n = Darwin.write(fd, pointer, remaining)
                #else
                let n = Glibc.write(fd, pointer, remaining)
                #endif
                if n > 0 {
                    remaining -= n
                    pointer = pointer.advanced(by: n)
                } else if n < 0, errno == EAGAIN || errno == EINTR, attempts < 200 {
                    attempts += 1
                    usleep(5_000)
                } else {
                    return false
                }
            }
            return true
        }
    }

    @discardableResult
    public func write(_ text: String) -> Bool { write(Data(text.utf8)) }

    /// Asks the process to stop (SIGTERM), then kills it (SIGKILL) if it is still running after `gracePeriod`.
    public func terminate(gracePeriod: TimeInterval = 2) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        queue.asyncAfter(deadline: .now() + gracePeriod) { [weak self] in
            guard let self, self.process.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    // MARK: Reading

    private func startReading() {
        let fd = masterFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            self.drain()
        }
        source.setCancelHandler {
            close(fd)
            self.readDidFinish()
        }
        readSource = source
        source.resume()
    }

    /// Reads whatever is available. End-of-file (or EIO, which is what macOS and Linux give once the
    /// child side has closed) ends reading.
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(masterFD, $0.baseAddress, $0.count) }
            if n > 0 {
                continuation.yield(.output(Data(buffer[0..<n])))
                if n < buffer.count { return }
            } else if n < 0, errno == EAGAIN || errno == EINTR {
                return
            } else {
                readSource?.cancel()
                return
            }
        }
    }

    private func readDidFinish() {
        lock.lock()
        readFinished = true
        masterFD = -1
        lock.unlock()
        readSource = nil
        finishIfDone()
    }

    private func processDidExit(_ p: Process) {
        let status: Int32 = p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
        p.terminationHandler = nil
        queue.async {
            self.exitStatus = status
            // Pick up anything still buffered, then give a grandchild that kept the terminal open a moment
            // before giving up on it (the master never reports end-of-file while any slave copy is open).
            self.drain()
            self.finishIfDone()
            self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.readSource?.cancel()
            }
        }
    }

    /// Runs on `queue`.
    private func finishIfDone() {
        guard !finished, readFinished, let status = exitStatus else { return }
        finished = true
        continuation.yield(.exited(status))
        continuation.finish()
    }
}
