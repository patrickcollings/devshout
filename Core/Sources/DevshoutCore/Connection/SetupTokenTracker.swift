import Foundation

/// Where connecting with `claude setup-token` has got to. The macOS `SetupTokenFlow` publishes this.
public enum SetupTokenStatus: Sendable, Hashable {
    case idle
    /// `claude setup-token` is starting.
    case starting
    /// The browser should be open on Claude's sign-in page. `signInURL` is set when the CLI showed it
    /// (so the sheet can offer "Open sign-in page" in case the browser didn't open).
    case waitingForBrowser(signInURL: URL?)
    /// The CLI is showing "Paste code here if prompted": the browser may show a code to paste back.
    /// The user may also still be signing in, so the sheet shows both.
    case needsCode(signInURL: URL?)
    /// A code was sent; waiting for the CLI to exchange it for a token.
    case verifyingCode
    /// The token was read and saved in the Keychain.
    case succeeded(ClaudeCredential)
    case failed(message: String)
    case cancelled

    /// The CLI is (or should be) running.
    public var isInProgress: Bool {
        switch self {
        case .starting, .waitingForBrowser, .needsCode, .verifyingCode: true
        case .idle, .succeeded, .failed, .cancelled: false
        }
    }

    public var isFinished: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        default: false
        }
    }

    public var signInURL: URL? {
        switch self {
        case .waitingForBrowser(let url), .needsCode(let url): url
        default: nil
        }
    }

    public var acceptsCode: Bool {
        if case .needsCode = self { return true }
        return false
    }

    /// One line for the connection sheet.
    public var title: String {
        switch self {
        case .idle: "Connect your Claude account"
        case .starting: "Starting Claude Code…"
        case .waitingForBrowser: "Finish signing in in your browser…"
        case .needsCode: "Finish signing in in your browser…"
        case .verifyingCode: "Checking the code…"
        case .succeeded: "Connected"
        case .failed: "Couldn't connect"
        case .cancelled: "Cancelled"
        }
    }

    /// A sentence or two under the title, when there is more to say.
    public var detail: String? {
        switch self {
        case .idle:
            "devshout runs claude setup-token, which opens Claude's own sign-in page. Approve access there and the token is kept in this Mac's Keychain."
        case .starting:
            nil
        case .waitingForBrowser(let url):
            url == nil
                ? "Approve access on Claude's page. devshout picks up the token by itself."
                : "Approve access on Claude's page. If your browser didn't open, use Open sign-in page."
        case .needsCode:
            "Approve access on Claude's page. If it shows a code instead of finishing by itself, paste the code here."
        case .verifyingCode:
            nil
        case .succeeded:
            "Your Claude token is saved in this Mac's Keychain. It lasts a year; devshout will remind you before it runs out."
        case .failed(let message):
            message
        case .cancelled:
            nil
        }
    }
}

/// What `SetupTokenFlow` should do next.
public enum SetupTokenAction: Sendable, Hashable {
    /// Save this token (with createdAt = now), then call `tokenSaved` or `saveFailed`.
    case saveToken(String)
    /// Stop the CLI.
    case terminate
}

/// The pure state machine behind `SetupTokenFlow`: feed it parsed output and process events, act on the
/// actions it returns, and publish `status`.
public struct SetupTokenTracker: Sendable {
    public private(set) var status: SetupTokenStatus = .idle
    public private(set) var latest: SetupTokenOutput = SetupTokenOutput()
    private var tokenHandedOut = false

    public init() {}

    public mutating func start() {
        status = .starting
        latest = SetupTokenOutput()
        tokenHandedOut = false
    }

    /// New output arrived; `output` is the parse of everything so far (with `finished: false`).
    public mutating func update(_ output: SetupTokenOutput) -> [SetupTokenAction] {
        latest = output
        guard status.isInProgress else { return [] }

        if let token = output.token {
            guard !tokenHandedOut else { return [] }
            tokenHandedOut = true
            return [.saveToken(token)]
        }
        if tokenHandedOut { return [] }  // saving; nothing else matters now

        if let error = output.errorMessage {
            status = .failed(message: Self.failureMessage(for: error))
            return [.terminate]
        }
        if case .verifyingCode = status { return [] }

        if output.isPromptingForCode {
            status = .needsCode(signInURL: output.signInURL)
        } else if output.signInURL != nil || Self.mentionsBrowser(output.screenText) {
            status = .waitingForBrowser(signInURL: output.signInURL)
        }
        return []
    }

    /// The code the user pasted has been written to the CLI.
    public mutating func codeSubmitted() {
        guard status.isInProgress, !tokenHandedOut else { return }
        status = .verifyingCode
    }

    public mutating func tokenSaved(_ credential: ClaudeCredential) -> [SetupTokenAction] {
        status = .succeeded(credential)
        return [.terminate]
    }

    public mutating func saveFailed(_ message: String) -> [SetupTokenAction] {
        status = .failed(message: "Claude gave devshout a token, but it couldn't be saved in the Keychain: \(message)")
        return [.terminate]
    }

    /// The CLI exited. `output` is the parse of everything it printed (with `finished: true`).
    public mutating func processExited(exitCode: Int32, output: SetupTokenOutput) -> [SetupTokenAction] {
        latest = output
        guard status.isInProgress else { return [] }
        if let token = output.token {
            if tokenHandedOut { return [] }
            tokenHandedOut = true
            return [.saveToken(token)]
        }
        if tokenHandedOut { return [] }
        if let error = output.errorMessage {
            status = .failed(message: Self.failureMessage(for: error))
        } else if exitCode == 127 {
            status = .failed(message: "Claude Code couldn't be started. Check that it's installed, then try again.")
        } else {
            let last = output.screenText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty && $0.contains(where: \.isLetter) })
            var message = exitCode == 0
                ? "claude setup-token finished without printing a token."
                : "claude setup-token stopped (exit code \(exitCode)) without printing a token."
            if let last { message += " It said: “\(last)”" }
            status = .failed(message: message)
        }
        return []
    }

    public mutating func cancel() -> [SetupTokenAction] {
        guard !status.isFinished else { return [] }
        status = .cancelled
        return [.terminate]
    }

    public mutating func timedOut(after seconds: TimeInterval) -> [SetupTokenAction] {
        guard status.isInProgress, !tokenHandedOut else { return [] }
        let minutes = max(1, Int((seconds / 60).rounded()))
        status = .failed(message: "Signing in took longer than \(minutes) minute\(minutes == 1 ? "" : "s"), so devshout stopped waiting. Try again when you're ready.")
        return [.terminate]
    }

    /// The process could not be launched at all.
    public mutating func launchFailed(_ message: String) {
        status = .failed(message: "Couldn't start claude setup-token: \(message)")
    }

    static func mentionsBrowser(_ screen: String) -> Bool {
        let lower = screen.lowercased()
        return lower.contains("browser") || lower.contains("sign in") || lower.contains("opening")
    }

    static func failureMessage(for error: String) -> String {
        var message = error
        if let last = message.last, !".!?".contains(last) { message += "." }
        let lower = error.lowercased()
        let suggestsRetry = lower.contains("oauth error") || lower.contains("invalid code") || lower.contains("code wasn't accepted")
        if suggestsRetry, !lower.contains("again") {
            message += " Try again to get a new sign-in link."
        }
        return message
    }
}
