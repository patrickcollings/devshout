import Foundation

/// Builds `claude setup-token` output the way Claude Code draws it (see `CapturedSetupToken` for real captures):
/// words placed with `ESC [ n G`, colours with SGR, every line ending "\r\r\n", redraws erasing lines with
/// `ESC [ 2K ESC [ 1A` and hard wrapping at the terminal width.
enum SetupTokenSamples {
    static let esc = "\u{1B}"

    /// A made-up token in the real shape (108 characters of base64url ending "AA"), built from a repeating
    /// pattern so secret scanners don't mistake it for a real one.
    static let token = "sk-ant-oat01-" + String(repeating: "aB3_-", count: 18) + "xyzAA"

    /// One line drawn like Ink: each word after the first placed with CHA, starting at column `indent + 1`.
    static func inkLine(_ text: String, indent: Int = 1, colour: String? = nil, width: Int = 4_000) -> String {
        var out = ""
        if let colour { out += "\(esc)[\(colour)m" }
        var column = indent + 1
        var first = true
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            if first {
                if indent > 0 { out += "\(esc)[\(column)G" }
                first = false
            } else {
                column += 1
                out += "\(esc)[\(column)G"
            }
            out += word
            column += word.count
        }
        if colour != nil { out += "\(esc)[39m" }
        return out + "\r\r\n"
    }

    /// `text` hard-wrapped at `width` columns, as Ink does for an unbreakable run of characters.
    static func wrapped(_ text: String, width: Int, colour: String? = nil) -> String {
        var out = ""
        var rest = Substring(text)
        while !rest.isEmpty {
            let piece = rest.prefix(width)
            rest = rest.dropFirst(piece.count)
            if let colour { out += "\(esc)[\(colour)m\(piece)\(esc)[39m" } else { out += piece }
            out += "\r\r\n"
        }
        return out
    }

    /// Ink erasing its last `count` lines before drawing the next frame.
    static func erase(lines count: Int) -> String {
        String(repeating: "\(esc)[2K\(esc)[1A", count: max(0, count - 1)) + "\(esc)[2K\(esc)[G"
    }

    /// The frame drawn after the code is accepted (strings from the CLI's `tokenOutput` component).
    static func successFrame(token: String = token, width: Int = 4_000, validFor: String = "1 year") -> String {
        var out = "\r\r\n"
        out += inkLine("✓ Long-lived authentication token created successfully!", colour: "38;5;114")
        out += "\r\r\n"
        out += inkLine("Your OAuth token (valid for \(validFor)):")
        out += "\r\r\n"
        out += width >= token.count + 1 ? "\(esc)[38;5;220m\(token)\(esc)[39m\r\r\n" : wrapped(token, width: width, colour: "38;5;220")
        out += "\r\r\n"
        out += inkLine("Store this token securely. You won't be able to see it again.", colour: "2")
        out += "\r\r\n"
        out += inkLine("Use this token by setting: export CLAUDE_CODE_OAUTH_TOKEN=<token>", colour: "2")
        return out
    }

    /// The real sign-in screen, the user's code echoed (masked, as the CLI does), the prompt erased, then success.
    static func fullSuccessfulRun(width: Int = 4_000) -> String {
        let signIn = width >= 1_000 ? CapturedSetupToken.wide : CapturedSetupToken.narrow
        return signIn
            + "\(esc)[?2004h\r\(esc)[31C\(esc)[1A**************#state\r\r\n"
            + erase(lines: 9)
            + successFrame(width: width)
            + "\(esc)[?25h\(esc)[?2004l"
    }

    /// Removes OSC 8 hyperlinks, leaving their visible text, as some terminals' output would look.
    static func withoutHyperlinks(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i...].hasPrefix("\(esc)]8;"), let bel = s[i...].firstIndex(of: "\u{07}") {
                i = s.index(after: bel)
                continue
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
