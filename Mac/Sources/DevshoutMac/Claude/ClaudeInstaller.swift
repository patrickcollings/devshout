// ClaudeInstaller: installs Claude Code with Anthropic's official installer, unmodified
// (`/bin/bash -c "curl -fsSL https://claude.ai/install.sh | bash"`), streaming its log; or opens the same command
// in Terminal. TerminalLauncher writes and opens the `.command` files.
//
// Unsure / unverified on macOS:
// - Type-checked on Linux with Combine and AppKit stand-ins, not built with the macOS SDK.
// - Opening a `.command` file we wrote ourselves (not quarantined) in Terminal shouldn't trigger Gatekeeper,
//   but macOS may ask once whether devshout may control or open Terminal.
// - The installer may print colours; the log is passed through TerminalRenderer to strip them.
// - Cancel relies on the SIGTERM trap in TerminalScript.cancellableInstallScript (uses /usr/bin/pgrep, which macOS
//   has); checked on Linux that no curl or bash is left behind.

import AppKit
import Combine
import DevshoutCore
import Foundation

@MainActor
public final class ClaudeInstaller: ObservableObject {
    public enum Status: Equatable, Sendable {
        case idle
        case running
        case succeeded
        case failed(message: String)
        case cancelled
    }

    @Published public private(set) var status: Status = .idle
    /// The installer's output so far, colours and cursor codes removed.
    @Published public private(set) var log: String = ""

    /// Called when a run ends (true when the installer succeeded); the app re-runs `ClaudeConnection.refresh()`.
    public var onFinished: ((Bool) -> Void)?

    private var process: Process?
    private var raw = Data()
    private var run = 0

    public init() {}

    /// Runs the official installer. Does nothing while it is already running.
    public func install() {
        guard status != .running else { return }
        run += 1
        let thisRun = run
        raw = Data()
        log = ""
        status = .running

        let pipe = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // The official one-liner, unmodified, wrapped so that cancelling also stops curl and the inner bash.
        p.arguments = ["-c", TerminalScript.cancellableInstallScript]
        p.environment = Self.environment()
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = pipe
        p.standardError = pipe

        let (events, continuation) = AsyncStream<InstallerEvent>.makeStream()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.yield(.endOfOutput)
            } else {
                continuation.yield(.output(data))
            }
        }
        p.terminationHandler = { process in
            continuation.yield(.exited(process.terminationStatus, signalled: process.terminationReason == .uncaughtSignal))
        }

        do {
            try p.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            finish(.failed(message: "Couldn't start the installer: \(error.localizedDescription)"))
            return
        }
        process = p

        Task { @MainActor [weak self] in
            var outputEnded = false
            var exitInfo: (code: Int32, signalled: Bool)?
            for await event in events {
                guard let self, self.run == thisRun else { break }
                switch event {
                case .output(let data):
                    if self.status == .cancelled { continue }
                    self.raw.append(data)
                    self.log = TerminalRenderer.render(String(decoding: self.raw, as: UTF8.self)).plainText
                case .endOfOutput:
                    outputEnded = true
                case .exited(let code, let signalled):
                    exitInfo = (code, signalled)
                }
                if outputEnded, let exit = exitInfo {
                    continuation.finish()
                    self.process = nil
                    if self.status == .cancelled { break }
                    if exit.code == 0, !exit.signalled {
                        self.finish(.succeeded)
                    } else {
                        let last = self.log.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                        var message = exit.signalled ? "The installer was stopped." : "The installer failed (exit code \(exit.code))."
                        if let last { message += " It said: “\(last.trimmingCharacters(in: .whitespaces))”" }
                        self.finish(.failed(message: message))
                    }
                    break
                }
            }
        }
    }

    public func cancel() {
        guard status == .running else { return }
        status = .cancelled
        process?.terminate()
        onFinished?(false)
    }

    /// The other button: the same official installer, in a Terminal window.
    public func openInTerminal() throws {
        try TerminalLauncher.open(script: TerminalScript.installClaude(), named: "devshout-install-claude")
    }

    private func finish(_ status: Status) {
        self.status = status
        onFinished?(status == .succeeded)
    }

    /// A clean environment: just enough for the installer to find curl and the home folder.
    static func environment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "PATH": ClaudeSetupCommand.systemPath.joined(separator: ":"),
            "LANG": inherited["LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "en_GB.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        if let shell = inherited["SHELL"], !shell.isEmpty { env["SHELL"] = shell }
        return env
    }
}

private enum InstallerEvent: Sendable {
    case output(Data)
    case endOfOutput
    case exited(Int32, signalled: Bool)
}

/// Writes a `.command` script to a temporary folder and opens it in Terminal.
public enum TerminalLauncher {
    public enum LaunchError: Error, LocalizedError {
        case couldNotOpen

        public var errorDescription: String? {
            "Couldn't open Terminal. The script is in your temporary folder if you'd like to run it yourself."
        }
    }

    /// - Returns: the script's location (it deletes itself once Terminal starts it).
    @MainActor
    @discardableResult
    public static func open(script: String, named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("devshout-terminal", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).command")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)

        let workspace = NSWorkspace.shared
        if let terminal = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            workspace.open([file], withApplicationAt: terminal, configuration: configuration, completionHandler: nil)
        } else if !workspace.open(file) {
            throw LaunchError.couldNotOpen
        }
        return file
    }
}
