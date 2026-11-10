// SetupTokenFlow: connects devshout to the user's Claude account by running `claude setup-token` in a
// pseudo-terminal, reading the printed token and saving it to the Keychain.
//
// The parsing and the state machine are in Core (SetupTokenParser, SetupTokenTracker) and tested on Linux.
// This file is the glue. Unsure / unverified on macOS:
// - It was type-checked and run on Linux against the real `claude setup-token` (with a Combine stand-in), not
//   built with the macOS SDK.
// - The code is typed into the CLI, then Return 150 ms later (as a person would). The CLI enables bracketed
//   paste but accepted typed input in testing.
// - On macOS `claude setup-token` opens the browser itself (with /usr/bin/open, which is on our PATH).

import Combine
import DevshoutCore
import Foundation

@MainActor
public final class SetupTokenFlow: ObservableObject {
    @Published public private(set) var status: SetupTokenStatus = .idle
    /// What the CLI's terminal shows now (never the token), for a "Show details" disclosure.
    @Published public private(set) var screenText: String = ""

    /// Called after a token has been saved, by either path.
    public var onSaved: ((ClaudeCredential) -> Void)?

    public let store: CredentialStore
    private let dateSource: DateSource
    /// Give up waiting for the browser approval after this long.
    public let timeout: TimeInterval

    private var tracker = SetupTokenTracker()
    private var terminal: PseudoTerminal?
    private var output = Data()
    private var run = 0
    private var eventsTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    /// More than any sign-in screen could need; past this the start of the output is dropped.
    private static let outputLimit = 4 * 1_024 * 1_024

    public init(store: CredentialStore, dateSource: DateSource = SystemDateSource(), timeout: TimeInterval = 600) {
        self.store = store
        self.dateSource = dateSource
        self.timeout = timeout
    }

    // MARK: In-app flow

    /// Runs `claude setup-token` (the binary at `claudeURL`) with a clean environment. Cancels a run in progress.
    public func start(claudeURL: URL) {
        stopCurrentRun()
        run += 1
        let thisRun = run
        output = Data()
        screenText = ""
        tracker.start()
        publish()

        let environment = ClaudeSetupCommand.environment(
            claudeExecutable: claudeURL,
            home: NSHomeDirectory(),
            user: NSUserName(),
            lang: ProcessInfo.processInfo.environment["LANG"],
            tmpDir: NSTemporaryDirectory()
        )
        let pty: PseudoTerminal
        do {
            pty = try PseudoTerminal(
                executable: claudeURL,
                arguments: ClaudeSetupCommand.arguments,
                environment: environment,
                currentDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                size: PseudoTerminal.Size(columns: ClaudeSetupCommand.columns, rows: ClaudeSetupCommand.rows)
            )
        } catch {
            tracker.launchFailed(error.localizedDescription)
            publish()
            return
        }
        terminal = pty

        eventsTask = Task { @MainActor [weak self] in
            for await event in pty.events {
                guard let self, self.run == thisRun else { return }
                self.handle(event)
            }
        }
        let limit = timeout
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled, let self, self.run == thisRun else { return }
            self.perform(self.tracker.timedOut(after: limit))
            self.publish()
        }
    }

    /// Sends the code the browser showed ("Paste code here if prompted").
    public func submitCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, status.isInProgress, let terminal else { return }
        terminal.write(trimmed)
        let thisRun = run
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, self.run == thisRun else { return }
            self.terminal?.write("\r")
        }
        tracker.codeSubmitted()
        publish()
    }

    /// Stops the CLI. The status becomes `.cancelled` unless it had already finished.
    public func cancel() {
        perform(tracker.cancel())
        publish()
    }

    // MARK: Manual path

    /// Saves a token the user made in Terminal and pasted. Throws `TokenValidationError` (its `message` is
    /// for the user) or the store's error.
    public func savePastedToken(_ text: String) throws {
        let token = try ClaudeTokenFormat.validate(text)
        if status.isInProgress { cancel() }
        stopCurrentRun()
        // We can't know when a pasted token was made, so the year is counted from now.
        let credential = ClaudeCredential(token: token, createdAt: dateSource.now())
        try store.save(credential)
        _ = tracker.tokenSaved(credential)
        publish()
        onSaved?(credential)
    }

    /// The fallback when the in-app flow fails: `claude setup-token` in Terminal, then paste the token.
    @discardableResult
    public func openInTerminal(claudeURL: URL) throws -> URL {
        try TerminalLauncher.open(script: TerminalScript.setupToken(claudeExecutable: claudeURL), named: "devshout-connect-claude")
    }

    // MARK: Events

    private func handle(_ event: PseudoTerminal.Event) {
        switch event {
        case .output(let data):
            output.append(data)
            if output.count > Self.outputLimit { output.removeFirst(output.count - Self.outputLimit / 2) }
            let parsed = SetupTokenParser.parse(output)
            screenText = parsed.screenText
            perform(tracker.update(parsed))
        case .exited(let code):
            let parsed = SetupTokenParser.parse(output, finished: true)
            screenText = parsed.screenText
            perform(tracker.processExited(exitCode: code, output: parsed))
            terminal = nil
            timeoutTask?.cancel()
        }
        publish()
    }

    private func perform(_ actions: [SetupTokenAction]) {
        for action in actions {
            switch action {
            case .saveToken(let token):
                let credential = ClaudeCredential(token: token, createdAt: dateSource.now())
                do {
                    try store.save(credential)
                    perform(tracker.tokenSaved(credential))
                    onSaved?(credential)
                } catch {
                    perform(tracker.saveFailed(error.localizedDescription))
                }
            case .terminate:
                timeoutTask?.cancel()
                // Give the CLI a moment to finish on its own after printing the token.
                let pty = terminal
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    pty?.terminate()
                }
            }
        }
    }

    private func stopCurrentRun() {
        run += 1  // late events from the old run are ignored
        terminal?.terminate(gracePeriod: 1)
        terminal = nil
        eventsTask?.cancel()
        eventsTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func publish() {
        if status != tracker.status { status = tracker.status }
    }
}
