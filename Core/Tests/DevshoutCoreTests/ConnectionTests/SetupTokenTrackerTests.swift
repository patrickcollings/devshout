import Foundation
import Testing
@testable import DevshoutCore

@Suite struct SetupTokenTrackerTests {
    static let credential = ClaudeCredential(token: SetupTokenSamples.token, createdAt: Date(timeIntervalSince1970: 1_794_312_000))

    @Test func happyPathWithCode() {
        var t = SetupTokenTracker()
        t.start()
        #expect(t.status == .starting)

        // Nothing useful yet: still starting.
        #expect(t.update(SetupTokenParser.parse("\u{1B}[?25l")).isEmpty)
        #expect(t.status == .starting)

        #expect(t.update(SetupTokenParser.parse(CapturedSetupToken.wide)).isEmpty)
        guard case .needsCode(let url) = t.status else { Issue.record("expected needsCode, got \(t.status)"); return }
        #expect(url?.absoluteString == SetupTokenParserTests.wideURL)
        #expect(t.status.acceptsCode)
        #expect(t.status.signInURL != nil)

        t.codeSubmitted()
        #expect(t.status == .verifyingCode)
        // The prompt is still drawn while the CLI checks the code: stay verifying.
        #expect(t.update(SetupTokenParser.parse(CapturedSetupToken.wide + "**#state")).isEmpty)
        #expect(t.status == .verifyingCode)

        let actions = t.update(SetupTokenParser.parse(SetupTokenSamples.fullSuccessfulRun()))
        #expect(actions == [.saveToken(SetupTokenSamples.token)])
        // The same token again is not handed out twice.
        #expect(t.update(SetupTokenParser.parse(SetupTokenSamples.fullSuccessfulRun())).isEmpty)
        #expect(t.processExited(exitCode: 0, output: SetupTokenParser.parse(SetupTokenSamples.fullSuccessfulRun(), finished: true)).isEmpty)

        #expect(t.tokenSaved(Self.credential) == [.terminate])
        #expect(t.status == .succeeded(Self.credential))
        #expect(t.status.isFinished)
    }

    @Test func browserRedirectWithoutCode() {
        var t = SetupTokenTracker()
        t.start()
        _ = t.update(SetupTokenParser.parse(SetupTokenSamples.inkLine("Opening browser to sign in…")))
        #expect(t.status == .waitingForBrowser(signInURL: nil))
        #expect(t.update(SetupTokenParser.parse(SetupTokenSamples.successFrame() + "\r\r\n")) == [.saveToken(SetupTokenSamples.token)])
    }

    @Test func rejectedCodeFails() {
        var t = SetupTokenTracker()
        t.start()
        _ = t.update(SetupTokenParser.parse(CapturedSetupToken.wide))
        t.codeSubmitted()
        let actions = t.update(SetupTokenParser.parse(CapturedSetupToken.rejectedCode))
        #expect(actions == [.terminate])
        guard case .failed(let message) = t.status else { Issue.record("expected failed"); return }
        #expect(message.hasPrefix("OAuth error: That code wasn't accepted."))
        #expect(message.hasSuffix("Sign in again to get a new code."))  // the CLI already says what to do
        var u = SetupTokenTracker()
        u.start()
        _ = u.update(SetupTokenParser.parse("OAuth error: invalid_grant\r\n"))
        #expect(u.status == .failed(message: "OAuth error: invalid_grant. Try again to get a new sign-in link."))
        // Exiting afterwards doesn't change the message.
        #expect(t.processExited(exitCode: 1, output: SetupTokenParser.parse(CapturedSetupToken.rejectedCode, finished: true)).isEmpty)
        #expect(t.status == .failed(message: message))
    }

    @Test func tokenOnlySeenAtExit() {
        var t = SetupTokenTracker()
        t.start()
        let raw = "Your OAuth token:\r\n\(SetupTokenSamples.token)"
        #expect(t.update(SetupTokenParser.parse(raw)).isEmpty)
        #expect(t.processExited(exitCode: 0, output: SetupTokenParser.parse(raw, finished: true)) == [.saveToken(SetupTokenSamples.token)])
        _ = t.tokenSaved(Self.credential)
        #expect(t.status == .succeeded(Self.credential))
    }

    @Test func exitWithoutToken() {
        var t = SetupTokenTracker()
        t.start()
        _ = t.processExited(exitCode: 1, output: SetupTokenParser.parse("Something odd happened\r\n", finished: true))
        #expect(t.status == .failed(message: "claude setup-token stopped (exit code 1) without printing a token. It said: “Something odd happened”"))

        t.start()
        _ = t.processExited(exitCode: 0, output: SetupTokenParser.parse("", finished: true))
        #expect(t.status == .failed(message: "claude setup-token finished without printing a token."))

        t.start()
        _ = t.processExited(exitCode: 127, output: SetupTokenParser.parse("", finished: true))
        #expect(t.status.title == "Couldn't connect")
    }

    @Test func exitWithErrorUsesTheError() {
        var t = SetupTokenTracker()
        t.start()
        _ = t.processExited(exitCode: 1, output: SetupTokenParser.parse("Error: Request failed with status code 403\r\n", finished: true))
        #expect(t.status == .failed(message: "Error: Request failed with status code 403."))
    }

    @Test func saveFailure() {
        var t = SetupTokenTracker()
        t.start()
        _ = t.update(SetupTokenParser.parse(SetupTokenSamples.successFrame() + "\r\r\n"))
        #expect(t.saveFailed("errSecAuthFailed") == [.terminate])
        guard case .failed(let m) = t.status else { Issue.record("expected failed"); return }
        #expect(m.contains("Keychain"))
    }

    @Test func cancelAndTimeout() {
        var t = SetupTokenTracker()
        t.start()
        #expect(t.cancel() == [.terminate])
        #expect(t.status == .cancelled)
        #expect(t.cancel().isEmpty)
        // Output after cancelling changes nothing.
        #expect(t.update(SetupTokenParser.parse(SetupTokenSamples.successFrame() + "\r\r\n")).isEmpty)
        #expect(t.status == .cancelled)

        t.start()
        #expect(t.timedOut(after: 600) == [.terminate])
        #expect(t.status == .failed(message: "Signing in took longer than 10 minutes, so devshout stopped waiting. Try again when you're ready."))
    }

    @Test func launchFailure() {
        var t = SetupTokenTracker()
        t.start()
        t.launchFailed("No such file or directory")
        #expect(t.status == .failed(message: "Couldn't start claude setup-token: No such file or directory"))
    }

    @Test func codeIgnoredWhenNotRunning() {
        var t = SetupTokenTracker()
        t.codeSubmitted()
        #expect(t.status == .idle)
    }

    @Test func statusCopy() {
        let all: [SetupTokenStatus] = [.idle, .starting, .waitingForBrowser(signInURL: nil),
                                       .waitingForBrowser(signInURL: URL(string: "https://claude.com/cai/oauth/authorize")),
                                       .needsCode(signInURL: nil), .verifyingCode, .succeeded(Self.credential),
                                       .failed(message: "x"), .cancelled]
        for s in all {
            #expect(!s.title.isEmpty)
            let text = (s.title + " " + (s.detail ?? "")).lowercased()
            #expect(!text.contains("authoriz"))
            #expect(!text.contains("api key"))
        }
        #expect(SetupTokenStatus.starting.isInProgress)
        #expect(!SetupTokenStatus.idle.isInProgress)
    }
}
