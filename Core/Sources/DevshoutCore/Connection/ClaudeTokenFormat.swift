import Foundation

/// The shape of a `claude setup-token` OAuth token (`sk-ant-oat01-…`), and checks for one pasted by hand.
///
/// devshout only ever uses this token, passed to `claude -p` as `CLAUDE_CODE_OAUTH_TOKEN`. API keys
/// (`sk-ant-api…`) are refused on purpose: clean-up runs on the user's Claude subscription only.
public enum ClaudeTokenFormat {
    public static let prefix = "sk-ant-"
    /// The prefix of OAuth tokens from `claude setup-token` and `/login`.
    public static let oauthPrefix = "sk-ant-oat"
    /// The prefix of Anthropic API keys, which devshout never accepts.
    public static let apiKeyPrefix = "sk-ant-api"
    /// Shorter than this can't be a whole token (real ones are about 108 characters).
    public static let minimumLength = 40
    public static let maximumLength = 512

    /// Characters a token is made of (base64url plus the dashes in its prefix).
    public static func isTokenCharacter(_ c: Character) -> Bool {
        guard c.isASCII, let v = c.asciiValue else { return false }
        return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x2D || v == 0x5F
    }

    /// Whether `token` looks like a whole OAuth token (not an API key, not cut short).
    public static func isPlausibleToken(_ token: String) -> Bool {
        (try? validate(token)) != nil
    }

    /// Cleans up what someone pasted (whitespace, surrounding quotes, an `export CLAUDE_CODE_OAUTH_TOKEN=`
    /// prefix, line breaks from a wrapped terminal) and checks the result.
    /// - Returns: the bare token.
    public static func validate(_ input: String) throws(TokenValidationError) -> String {
        let token = normalise(input)
        guard !token.isEmpty else { throw .empty }
        if token.hasPrefix(apiKeyPrefix) { throw .apiKey }
        guard token.hasPrefix(prefix) else { throw .wrongPrefix }
        guard token.allSatisfy(isTokenCharacter) else { throw .invalidCharacters }
        guard token.count >= minimumLength else { throw .tooShort }
        guard token.count <= maximumLength else { throw .tooLong }
        return token
    }

    /// Strips what commonly comes along with a copied token. Does not check the result.
    public static func normalise(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // "export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-…" or "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-…"
        for lead in ["export ", "set "] where s.lowercased().hasPrefix(lead) {
            s = String(s.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
        }
        if let eq = s.firstIndex(of: "="), s[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            s = String(s[s.index(after: eq)...])
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Quotes, and a trailing semicolon from a shell line.
        if s.hasSuffix(";") { s.removeLast() }
        let quotes: Set<Character> = ["\"", "'", "`", "“", "”", "‘", "’"]
        while let first = s.first, quotes.contains(first) { s.removeFirst() }
        while let last = s.last, quotes.contains(last) { s.removeLast() }
        // A token copied from a narrow terminal can come with line breaks (and indentation) inside it.
        s = String(s.filter { !$0.isWhitespace })
        return s
    }
}

/// Why a pasted token was refused. `message` is shown under the paste field.
public enum TokenValidationError: Error, Sendable, Hashable {
    case empty
    case apiKey
    case wrongPrefix
    case invalidCharacters
    case tooShort
    case tooLong

    public var message: String {
        switch self {
        case .empty:
            "Paste the token that claude setup-token printed."
        case .apiKey:
            "That's an Anthropic API key. devshout only uses your Claude subscription: run claude setup-token and paste the token it prints (it starts sk-ant-oat)."
        case .wrongPrefix:
            "That doesn't look like a Claude token. Tokens from claude setup-token start with sk-ant-."
        case .invalidCharacters:
            "The token contains characters a Claude token can't have. Copy it again, without anything around it."
        case .tooShort:
            "That token looks cut short. Copy the whole line that starts with sk-ant-."
        case .tooLong:
            "That's too long to be a Claude token. Copy just the line that starts with sk-ant-."
        }
    }
}

extension TokenValidationError: LocalizedError {
    public var errorDescription: String? { message }
}
