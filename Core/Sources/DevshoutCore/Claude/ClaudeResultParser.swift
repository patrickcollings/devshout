import Foundation

/// The parts of `claude -p --output-format json` we use. Every field is optional and unknown fields are ignored, so
/// a newer Claude Code that adds or drops fields still parses.
public struct ClaudeOutput: Sendable, Hashable, Decodable {
    public struct Usage: Sendable, Hashable, Decodable {
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var cacheCreationInputTokens: Int?
        public var cacheReadInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }

    public var type: String?
    /// `success`, `error_max_turns`, `error_during_execution`, …
    public var subtype: String?
    public var isError: Bool?
    public var result: String?
    public var durationMs: Double?
    public var durationApiMs: Double?
    public var numTurns: Int?
    public var sessionId: String?
    public var totalCostUSD: Double?
    public var usage: Usage?
    /// The HTTP status of a failed API call (seen in 2.1.322: `"api_error_status":401`).
    public var apiErrorStatus: Int?
    /// Why the run ended (seen in 2.1.322: `"terminal_reason":"api_error"`).
    public var terminalReason: String?
    /// Model names that answered (keys of `modelUsage`), e.g. `claude-haiku-4-5-20251001`.
    public var models: [String]

    enum CodingKeys: String, CodingKey {
        case type, subtype, result, usage, modelUsage
        case isError = "is_error"
        case durationMs = "duration_ms"
        case durationApiMs = "duration_api_ms"
        case numTurns = "num_turns"
        case sessionId = "session_id"
        case totalCostUSD = "total_cost_usd"
        case apiErrorStatus = "api_error_status"
        case terminalReason = "terminal_reason"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        subtype = try? c.decodeIfPresent(String.self, forKey: .subtype)
        isError = try? c.decodeIfPresent(Bool.self, forKey: .isError)
        result = try? c.decodeIfPresent(String.self, forKey: .result)
        durationMs = try? c.decodeIfPresent(Double.self, forKey: .durationMs)
        durationApiMs = try? c.decodeIfPresent(Double.self, forKey: .durationApiMs)
        numTurns = try? c.decodeIfPresent(Int.self, forKey: .numTurns)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        totalCostUSD = try? c.decodeIfPresent(Double.self, forKey: .totalCostUSD)
        usage = try? c.decodeIfPresent(Usage.self, forKey: .usage)
        apiErrorStatus = try? c.decodeIfPresent(Int.self, forKey: .apiErrorStatus)
        terminalReason = try? c.decodeIfPresent(String.self, forKey: .terminalReason)
        let modelUsage = try? c.decodeIfPresent([String: IgnoredValue].self, forKey: .modelUsage)
        models = modelUsage.map { Array($0.keys).sorted() } ?? []
    }

    public init(type: String? = "result", subtype: String? = nil, isError: Bool? = nil, result: String? = nil,
                durationMs: Double? = nil, totalCostUSD: Double? = nil, models: [String] = []) {
        self.type = type
        self.subtype = subtype
        self.isError = isError
        self.result = result
        self.durationMs = durationMs
        self.totalCostUSD = totalCostUSD
        self.models = models
    }

    /// Accepts any JSON value and keeps nothing.
    private struct IgnoredValue: Decodable, Sendable {
        init(from decoder: Decoder) throws {}
    }
}

/// Turns a finished `claude -p` run into clean-up text or a `CleanError`.
public enum ClaudeResultParser {
    /// Finds the result object in stdout. Tolerates log lines before or after it and returns nil for non-JSON.
    public static func decode(_ data: Data) -> ClaudeOutput? {
        let decoder = JSONDecoder()
        func attempt(_ bytes: Data) -> ClaudeOutput? {
            guard let output = try? decoder.decode(ClaudeOutput.self, from: bytes) else { return nil }
            // An object with none of the fields we know isn't a result.
            guard output.result != nil || output.isError != nil || output.type == "result" else { return nil }
            return output
        }
        if let output = attempt(data) { return output }
        let text = String(decoding: data, as: UTF8.self)
        // Newline-delimited output (or stray lines around the JSON): the last line that parses wins.
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }
            if let output = attempt(Data(trimmed.utf8)) { return output }
        }
        // Pretty-printed JSON surrounded by noise.
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last {
            if let output = attempt(Data(text[first...last].utf8)) { return output }
        }
        return nil
    }

    /// Maps a run to the cleaned text (already passed through `cleanText`) or the reason to paste raw instead.
    /// Timeouts are the caller's to report (it knows the limit it set).
    public static func interpret(_ run: ProcessResult) -> Result<String, CleanError> {
        let output = decode(run.stdout)
        let stderr = run.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let output else {
            let stdout = run.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if run.exitCode != 0 {
                let message = firstNonEmpty(stderr, stdout) ?? "claude exited with code \(run.exitCode)"
                return .failure(failure(exitCode: run.exitCode, message: message))
            }
            if stdout.isEmpty {
                return .failure(.rejectedOutput(reason: firstNonEmpty(stderr).map { "No output from Claude: \($0)" }
                    ?? "No output from Claude"))
            }
            return .failure(.rejectedOutput(reason: "Claude's output wasn't in the expected format: \(snippet(stdout))"))
        }

        let resultText = output.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let failed = run.exitCode != 0 || output.isError == true
            || (output.subtype.map { $0.hasPrefix("error") } ?? false)
        if failed {
            var message = firstNonEmpty(resultText, stderr) ?? ""
            if message.isEmpty {
                message = output.subtype.map { "Claude stopped early (\($0))" } ?? "Claude reported an error"
            }
            if output.apiErrorStatus == 401 {
                return .failure(.authFailed(message: snippet(message)))
            }
            return .failure(failure(exitCode: run.exitCode, message: message))
        }

        let cleaned = cleanText(resultText)
        if cleaned.isEmpty {
            return .failure(.rejectedOutput(reason: "Claude returned no text"))
        }
        return .success(cleaned)
    }

    private static func failure(exitCode: Int32, message: String) -> CleanError {
        looksLikeAuthFailure(message)
            ? .authFailed(message: snippet(message))
            : .processFailed(exitCode: exitCode, message: snippet(message))
    }

    /// True when an error message is about sign-in rather than anything else: 401, OAuth, authentication, login,
    /// token problems. Messages about output-token limits or rate limits don't count.
    public static func looksLikeAuthFailure(_ message: String) -> Bool {
        let text = message.lowercased()
        let notAuth = ["output token", "max_output_tokens", "tokens per", "rate limit", "rate_limit", "usage limit",
                       "overloaded", "context window", "prompt is too long", "unexpected token", "json parse",
                       "syntaxerror"]
        if notAuth.contains(where: text.contains) { return false }
        // "token" alone is too broad (Node's "Unexpected token"), so it needs a sign-in word next to it.
        let patterns = [
            #"\b401\b"#, #"oauth"#, #"authenticat"#, #"unauthori[sz]ed"#, #"\blog ?in\b"#, #"/login"#,
            #"logged (in|out)"#, #"\b(access|auth|api|setup|bearer|session|refresh) token"#,
            #"\btoken (has )?(expired|been revoked|was revoked|revoked|is invalid|invalid|is missing|missing)"#,
            #"(invalid|expired|revoked|missing) (oauth |access |auth )?token"#, #"invalid api key"#,
            #"credentials?\b"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Strips a code fence wrapped round the whole answer and any stray `<transcript>` tags.
    public static func cleanText(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result = stripWrappingFence(result)
        if let regex = try? NSRegularExpression(pattern: #"<\s*/?\s*transcript\b[^>]*>"#, options: [.caseInsensitive]) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: "")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // A fence inside the tags (`<transcript>```…```</transcript>`) is only visible now.
        return stripWrappingFence(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ```` ```lang\n…\n``` ```` → `…`, only when the fence wraps everything. Fences inside Structure's Markdown stay.
    static func stripWrappingFence(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2,
              let first = lines.first?.trimmingCharacters(in: .whitespaces),
              let last = lines.last?.trimmingCharacters(in: .whitespaces),
              first.hasPrefix("```") || first.hasPrefix("~~~"),
              last == String(first.prefix(3)) else { return text }
        let info = first.dropFirst(3)
        // An info string with spaces is prose after a fence, not a language tag.
        guard !info.contains(" ") else { return text }
        let inner = lines.dropFirst().dropLast()
        // If another bare fence sits inside, the outer pair isn't a single wrapper (e.g. two code blocks).
        if inner.contains(where: { $0.trimmingCharacters(in: .whitespaces) == String(first.prefix(3)) }) {
            return text
        }
        return inner.joined(separator: "\n")
    }

    private static func firstNonEmpty(_ values: String...) -> String? {
        values.first { !$0.isEmpty }
    }

    static func snippet(_ text: String, limit: Int = 500) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
