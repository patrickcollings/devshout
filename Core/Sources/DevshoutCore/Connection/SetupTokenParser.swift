import Foundation

/// What `claude setup-token` has shown so far.
public struct SetupTokenOutput: Sendable, Hashable {
    /// The OAuth token, once it has been printed in full.
    public var token: String?
    /// The sign-in page the CLI offers when the browser didn't open (the latest one, after a retry).
    public var signInURL: URL?
    /// The "Paste code here if prompted" field is on screen.
    public var isPromptingForCode: Bool
    /// An error currently on screen (or, once the process has ended, the last one printed).
    public var errorMessage: String?
    /// The CLI is offering "Press Enter to retry".
    public var isOfferingRetry: Bool
    /// How long the CLI said the token is valid for ("valid for 1 year"), in seconds, when it said so.
    public var statedValidity: TimeInterval?
    /// What the terminal shows now, for a "Details" disclosure and for logs. Never contains the token
    /// (it is replaced with a placeholder).
    public var screenText: String

    public init(token: String? = nil, signInURL: URL? = nil, isPromptingForCode: Bool = false,
                errorMessage: String? = nil, isOfferingRetry: Bool = false, statedValidity: TimeInterval? = nil,
                screenText: String = "") {
        self.token = token
        self.signInURL = signInURL
        self.isPromptingForCode = isPromptingForCode
        self.errorMessage = errorMessage
        self.isOfferingRetry = isOfferingRetry
        self.statedValidity = statedValidity
        self.screenText = screenText
    }

    /// Anything at all is on screen.
    public var hasVisibleText: Bool { !screenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Reads the raw PTY output of `claude setup-token` (ANSI colours, cursor movement, carriage returns, OSC 8
/// links, redraws, and hard line wrapping when the terminal is narrow).
///
/// Call it with everything read so far. With `finished: false` a token or URL at the very end of the output is
/// not reported yet, because the rest of it may still be on its way.
public enum SetupTokenParser {
    public static func parse(_ data: Data, finished: Bool = false) -> SetupTokenOutput {
        parse(String(decoding: data, as: UTF8.self), finished: finished)
    }

    public static func parse(_ raw: String, finished: Bool = false) -> SetupTokenOutput {
        let rendered = TerminalRenderer.render(raw)
        let plain = rendered.plainLines.map(cleanLine)
        let screen = rendered.screenLines.map(cleanLine)

        let token = findToken(in: plain, finished: finished)
        let url = findSignInURL(hyperlinks: rendered.hyperlinks, plain: plain, finished: finished)

        let lowerScreen = screen.map { $0.lowercased() }
        let prompting = lowerScreen.contains(where: isCodePrompt)
        let retry = lowerScreen.contains { $0.contains("press enter to retry") || $0.contains("enter to try again") }
        var error = screen.last(where: isErrorLine)
        if error == nil, finished { error = plain.last(where: isErrorLine) }

        var screenText = rendered.screenLines.joined(separator: "\n")
        if let token { screenText = screenText.replacingOccurrences(of: token, with: "sk-ant-…") }
        screenText = screenText.trimmingCharacters(in: .newlines)

        return SetupTokenOutput(
            token: token,
            signInURL: url,
            isPromptingForCode: prompting && token == nil,
            errorMessage: error,
            isOfferingRetry: retry,
            statedValidity: statedValidity(in: plain),
            screenText: screenText
        )
    }

    // MARK: Lines

    /// Box-drawing borders Ink may draw around text.
    static let borderCharacters: Set<Character> = ["│", "┃", "║", "|", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘"]

    static func cleanLine(_ line: String) -> String {
        var s = Substring(line.trimmingCharacters(in: .whitespaces))
        while let f = s.first, borderCharacters.contains(f) { s = s.dropFirst().drop(while: { $0 == " " }) }
        while let l = s.last, borderCharacters.contains(l) { s = Substring(String(s.dropLast()).trimmingTrailingWhitespace()) }
        return String(s)
    }

    static func isCodePrompt(_ lower: String) -> Bool {
        lower.contains("paste code here") || lower.contains("paste the code") || lower.contains("paste your code")
            || lower.contains("paste the authorization code") || lower.contains("paste the authorisation code")
            || lower.contains("enter the code") || lower.contains("paste code if prompted")
    }

    static func isErrorLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.isEmpty { return false }
        // Not fatal: a browser that failed to open just means the URL is shown instead.
        if lower.contains("browser") && !lower.contains("oauth error") { return false }
        return lower.contains("oauth error")
            || lower.hasPrefix("error:") || lower.hasPrefix("error ") || lower.hasPrefix("✗") || lower.hasPrefix("×")
            || lower.contains("failed to authenticate") || lower.contains("authentication failed")
            || lower.contains("login failed") || lower.contains("sign-in failed") || lower.contains("sign in failed")
            || lower.contains("invalid code") || lower.contains("code wasn't accepted") || lower.contains("does not permit")
            || lower.contains("requires a claude subscription") || lower.contains("timed out")
    }

    // MARK: Token

    static func findToken(in lines: [String], finished: Bool) -> String? {
        let terminated = finished ? lines.count : lines.count - 1
        var found: String?
        for (index, line) in lines.enumerated() {
            var searchStart = line.startIndex
            while let r = line.range(of: ClaudeTokenFormat.prefix, range: searchStart..<line.endIndex) {
                // Must start a word: not glued to other token characters ("xsk-ant-…").
                if r.lowerBound > line.startIndex, ClaudeTokenFormat.isTokenCharacter(line[line.index(before: r.lowerBound)]) {
                    searchStart = r.upperBound
                    continue
                }
                var end = r.upperBound
                while end < line.endIndex, ClaudeTokenFormat.isTokenCharacter(line[end]) { end = line.index(after: end) }
                var token = String(line[r.lowerBound..<end])
                var lastLine = index
                var complete = end < line.endIndex  // something follows on the same line

                if !complete {
                    // Hard-wrapped by a narrow terminal: the rest is on the following line(s), on its own.
                    // Only lines that have ended count: the last one may still be arriving.
                    var k = index + 1
                    while k < terminated, token.count < ClaudeTokenFormat.maximumLength {
                        let next = lines[k]
                        guard !next.isEmpty, !next.hasPrefix(ClaudeTokenFormat.prefix),
                              next.allSatisfy(ClaudeTokenFormat.isTokenCharacter) else { break }
                        token += next
                        lastLine = k
                        k += 1
                    }
                    // Complete once a line that has ended (even an empty one) follows the last fragment.
                    complete = lastLine + 1 < terminated
                }
                if (complete || finished), !token.hasPrefix(ClaudeTokenFormat.apiKeyPrefix),
                   ClaudeTokenFormat.isPlausibleToken(token) {
                    found = token
                }
                searchStart = end
            }
        }
        return found
    }

    // MARK: Sign-in URL

    static func isURLCharacter(_ c: Character) -> Bool {
        guard c.isASCII, let v = c.asciiValue, v > 0x20, v < 0x7F else { return false }
        return !"<>\"`{}|\\^ ".contains(c)
    }

    /// A URL that signs in to Claude, rather than (say) a link to the docs.
    static func isSignInURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        let s = url.absoluteString.lowercased()
        return s.contains("oauth") || s.contains("authorize") || s.contains("client_id=") || s.contains("/login")
    }

    static func isClaudeHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["claude.ai", "claude.com", "anthropic.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func findSignInURL(hyperlinks: [String], plain: [String], finished: Bool) -> URL? {
        let linked = hyperlinks.compactMap { URL(string: $0) }
        if let url = linked.last(where: isSignInURL) { return url }

        let terminated = finished ? plain.count : plain.count - 1
        var printed: [URL] = []
        for (index, line) in plain.enumerated() {
            var searchStart = line.startIndex
            while let r = line.range(of: "https://", options: .caseInsensitive, range: searchStart..<line.endIndex) {
                var end = r.upperBound
                while end < line.endIndex, isURLCharacter(line[end]) { end = line.index(after: end) }
                var text = String(line[r.lowerBound..<end])
                var complete = end < line.endIndex
                if !complete {
                    var lastLine = index
                    var k = index + 1
                    while k < terminated, text.count < 8_192 {
                        let next = plain[k]
                        guard !next.isEmpty, !next.lowercased().hasPrefix("http"), next.allSatisfy(isURLCharacter) else { break }
                        text += next
                        lastLine = k
                        k += 1
                    }
                    complete = lastLine + 1 < terminated
                }
                searchStart = end
                guard complete || finished else { continue }
                while let last = text.last, ".,;:!?'\")]".contains(last) {
                    if last == ")", text.contains("(") { break }
                    text.removeLast()
                }
                if let url = URL(string: text) { printed.append(url) }
            }
        }
        if let url = printed.last(where: isSignInURL) { return url }
        if let url = linked.last(where: { isClaudeHost($0) && !isDocsURL($0) }) { return url }
        return printed.last(where: { isClaudeHost($0) && !isDocsURL($0) })
    }

    static func isDocsURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.hasPrefix("docs.") || host.hasPrefix("code.") || host.hasPrefix("support.") || url.path.lowercased().contains("/docs")
    }

    // MARK: Validity

    /// "Your OAuth token (valid for 1 year):" → 365 days. Understands years, months, weeks, days and hours.
    static func statedValidity(in lines: [String]) -> TimeInterval? {
        for line in lines.reversed() {
            let lower = line.lowercased()
            guard let r = lower.range(of: "valid for ") else { continue }
            let words = lower[r.upperBound...].split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            guard words.count >= 2 else { continue }
            let amount: Double
            if let n = Double(words[0]) { amount = n } else if words[0] == "a" || words[0] == "an" || words[0] == "one" { amount = 1 } else { continue }
            let unit = words[1]
            let day: TimeInterval = 86_400
            switch true {
            case unit.hasPrefix("year"): return amount * 365 * day
            case unit.hasPrefix("month"): return amount * 30 * day
            case unit.hasPrefix("week"): return amount * 7 * day
            case unit.hasPrefix("day"): return amount * day
            case unit.hasPrefix("hour"): return amount * 3_600
            default: continue
            }
        }
        return nil
    }
}
