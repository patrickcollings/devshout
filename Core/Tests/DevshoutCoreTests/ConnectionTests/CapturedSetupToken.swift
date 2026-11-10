import Foundation

// Real `claude setup-token` output (Claude Code 2.1.322), captured byte for byte from a PTY on 2026-11-10 with
// TERM=xterm-256color, in Fixtures/setup-token-*.txt. To refresh them, run the CLI under a PTY (for example
// Python's pty module) at the stated width, save everything read from the master, and stop it at the prompt.
// Nothing in them is secret: the URLs carry a one-off PKCE challenge and state, and no token was ever issued.
// The success screen can't be captured without signing in, so `SetupTokenSamples` builds it from the strings
// in the CLI (its `tokenOutput` component), drawn in the same style as the captured screens.

enum CapturedSetupToken {
    /// 4,000 columns: the sign-in screen as devshout's PTY sees it (browser didn't open).
    static let wide = load("setup-token-wide")
    /// 80 columns: the same screen, hard-wrapped by Ink; each URL fragment is its own OSC 8 link.
    static let narrow = load("setup-token-narrow")
    /// 4,000 columns: a made-up code typed at the prompt, then Claude Code's "OAuth error" and "Press Enter to retry".
    static let rejectedCode = load("setup-token-rejected-code")

    private static func load(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Missing fixture Fixtures/\(name).txt")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
