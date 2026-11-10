// Terminal helpers for devshout-cli: stderr output, reading stdin (with echo off for secrets), progress lines,
// and one-shot stop signals for `record`.
//
// Unsure on macOS (written on Linux, type-checked there against stand-ins for DevshoutMac, never run on a Mac):
// - termios: `tcflag_t(ECHO)` and `c_lflag` are UInt on Darwin and UInt32 on Linux; the code converts explicitly.
// - Restoring echo from a SIGINT handler (a @convention(c) closure reading a global) if Ctrl-C is pressed while
//   the token prompt is showing.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import DevshoutCore
import Foundation

/// A failure with a message for the user. ArgumentParser prints it as "Error: …" and exits with status 1.
struct CLIError: Error, CustomStringConvertible, LocalizedError {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}

enum Console {
    private static let lock = NSLock()

    /// A line on stderr.
    static func error(_ text: String) {
        raw(text + "\n")
    }

    /// Text on stderr without a line break (for progress lines redrawn with "\r").
    static func raw(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// A line on stdout, flushed (stdout is what scripts and `>` capture).
    static func out(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        print(text)
        fflush(stdout)
    }

    static var stdinIsTerminal: Bool { isatty(STDIN_FILENO) == 1 }
    static var stderrIsTerminal: Bool { isatty(STDERR_FILENO) == 1 }

    /// Everything on stdin as text. When stdin is a terminal, `hint` is shown first (end with Ctrl-D).
    static func readAllStdin(hint: String? = nil) -> String {
        if stdinIsTerminal, let hint { error(hint) }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    /// One line from the terminal with echo turned off (for tokens). Nil at end of input.
    static func readSecretLine(prompt: String) -> String? {
        raw(prompt)
        guard stdinIsTerminal else { return readLine(strippingNewline: true) }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return readLine(strippingNewline: true) }
        var silent = original
        silent.c_lflag &= ~tcflag_t(ECHO)
        savedTerminal = original
        let previousHandler = signal(SIGINT, restoreTerminalAndExit)
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &silent)
        let line = readLine(strippingNewline: true)
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
        signal(SIGINT, previousHandler)
        savedTerminal = nil
        raw("\n")
        return line
    }
}

/// The terminal settings to put back if Ctrl-C arrives while echo is off.
private var savedTerminal: termios?

private let restoreTerminalAndExit: @convention(c) (Int32) -> Void = { _ in
    if var saved = savedTerminal { _ = tcsetattr(STDIN_FILENO, TCSANOW, &saved) }
    _exit(130)
}

/// Prints model download and load progress on one redrawn stderr line (or one line per phase when stderr is not a
/// terminal). Safe to call from any thread.
final class ProgressPrinter: @unchecked Sendable {
    private let label: String
    private let lock = NSLock()
    private var lastPhase: ModelProgress.Phase?
    private var lastPrint: TimeInterval = 0
    private var lineOpen = false
    private let redraw = Console.stderrIsTerminal

    init(label: String) {
        self.label = label
    }

    func update(_ progress: ModelProgress) {
        lock.lock()
        defer { lock.unlock() }
        let now = SpikeClock.now()
        let phaseChanged = progress.phase != lastPhase
        guard phaseChanged || now - lastPrint >= 0.2 else { return }
        lastPhase = progress.phase
        lastPrint = now
        let line = "\(label): \(Self.describe(progress))"
        if redraw {
            Console.raw("\r\u{1B}[K" + line)
            lineOpen = true
        } else if phaseChanged {
            Console.error(line)
        }
    }

    /// Ends the progress line.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        if lineOpen { Console.raw("\n") }
        lineOpen = false
    }

    static func describe(_ progress: ModelProgress) -> String {
        var text: String
        switch progress.phase {
        case .downloading: text = "downloading"
        case .compiling: text = "compiling for this Mac (first run only; can take a minute or two)"
        case .loading: text = "loading"
        case .ready: text = "ready"
        }
        if progress.phase != .ready, let fraction = progress.fraction {
            text += String(format: " %.0f%%", fraction * 100)
        }
        if progress.phase == .downloading, let total = progress.bytesTotal {
            text += " of about \(SpikeFormat.bytes(total))"
        }
        return text
    }
}

/// Fires once; any number of tasks can wait for it.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock()
        guard !fired else {
            lock.unlock()
            return
        }
        fired = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// A value shared between threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ change: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&value)
    }
}
