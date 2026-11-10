import Foundation

// Small pure helpers for the Phase 0 spike tool (`devshout-cli`): a monotonic clock, timing statistics,
// number formatting and the folders the CLI shares with the app. Foundation only, so it is tested on Linux.

/// A monotonic clock in seconds (not wall-clock time, so it never jumps).
public enum SpikeClock {
    public static func now() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

/// Min, median, max and mean of a set of timings.
public struct TimingStats: Codable, Sendable, Hashable {
    public var count: Int
    public var min: TimeInterval
    public var median: TimeInterval
    public var max: TimeInterval
    public var mean: TimeInterval

    /// Nil for an empty list. The median of an even count is the mean of the middle two.
    public init?(_ values: [TimeInterval]) {
        let sorted = values.filter(\.isFinite).sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }
        count = sorted.count
        min = first
        max = last
        mean = sorted.reduce(0, +) / Double(sorted.count)
        let middle = sorted.count / 2
        median = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// "min 0.41 s · median 0.45 s · max 0.60 s (10 runs)".
    public var summary: String {
        "min \(SpikeFormat.seconds(min)) · median \(SpikeFormat.seconds(median)) · max \(SpikeFormat.seconds(max)) "
            + "(\(count) \(count == 1 ? "run" : "runs"))"
    }
}

/// Text formatting for the spike tool's output. British English, SI units.
public enum SpikeFormat {
    /// 0.0123 → "12 ms", 1.234 → "1.23 s", 75.2 → "75.2 s".
    public static func seconds(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "–" }
        if abs(value) < 1 { return String(format: "%.0f ms", value * 1000) }
        if abs(value) < 10 { return String(format: "%.2f s", value) }
        return String(format: "%.1f s", value)
    }

    /// 83.4 → "01:23.4".
    public static func clock(_ value: TimeInterval) -> String {
        let safe = value.isFinite ? Swift.max(0, value) : 0
        let tenths = Int((safe * 10).rounded(.down))
        let minutes = tenths / 600
        let rest = Double(tenths % 600) / 10
        return String(format: "%02d:%04.1f", minutes, rest)
    }

    /// 483_200_000 → "483 MB" (decimal megabytes, as Finder shows them).
    public static func bytes(_ value: Int64) -> String {
        let v = Double(value)
        if v >= 1_000_000_000 { return String(format: "%.2f GB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.0f MB", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0f KB", v / 1_000) }
        return "\(value) bytes"
    }

    /// Processing time divided by audio duration (lower is faster), or nil without audio.
    public static func realTimeFactor(processing: TimeInterval, audio: TimeInterval) -> Double? {
        guard audio > 0, processing.isFinite, processing >= 0 else { return nil }
        return processing / audio
    }

    /// "RTF 0.012 (83× faster than real time)".
    public static func realTimeFactorDescription(_ rtf: Double?) -> String {
        guard let rtf, rtf.isFinite else { return "RTF –" }
        guard rtf > 0 else { return "RTF 0" }
        let speed = 1 / rtf
        let words = speed >= 1
            ? String(format: "%.0f× faster than real time", speed)
            : String(format: "%.1f× slower than real time", rtf)
        return String(format: "RTF %.3f", rtf) + " (\(words))"
    }

    /// A text level meter: `[########----------------]` for a value in 0...1.
    public static func meter(_ value: Float, width: Int = 24) -> String {
        let width = Swift.max(1, width)
        let clamped = value.isFinite ? Swift.min(1, Swift.max(0, value)) : 0
        let filled = Int((clamped * Float(width)).rounded())
        return "[" + String(repeating: "#", count: filled) + String(repeating: "-", count: width - filled) + "]"
    }

    /// "sk-ant-oat01-…wxyz": enough to tell tokens apart, never the whole thing.
    public static func maskedToken(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 16 else { return String(repeating: "•", count: Swift.min(8, trimmed.count)) }
        let head: String
        if trimmed.hasPrefix(ClaudeTokenFormat.oauthPrefix), let dash = trimmed.dropFirst(ClaudeTokenFormat.oauthPrefix.count).firstIndex(of: "-") {
            head = String(trimmed[..<trimmed.index(after: dash)])
        } else {
            head = String(trimmed.prefix(7))
        }
        return head + "…" + String(trimmed.suffix(4))
    }
}

/// The folders the spike tool shares with the app, under `~/Library/Application Support/devshout/` (PLAN §3.5, §5.1).
public struct SpikePaths: Sendable, Hashable {
    /// `~/Library/Application Support/devshout`.
    public var devshoutFolder: URL

    public init(devshoutFolder: URL) {
        self.devshoutFolder = devshoutFolder
    }

    /// Given the user's Application Support folder.
    public init(applicationSupport: URL) {
        self.init(devshoutFolder: applicationSupport.appendingPathComponent("devshout", isDirectory: true))
    }

    /// The default for this user (`~/Library/Application Support/devshout` on macOS).
    public static var `default`: SpikePaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return SpikePaths(applicationSupport: base)
    }

    /// devshout's own, empty `CLAUDE_CONFIG_DIR`, so the user's hooks, plugins and CLAUDE.md never load.
    public var claudeConfigDirectory: URL { devshoutFolder.appendingPathComponent("claude", isDirectory: true) }
    /// An empty folder `claude -p` runs in, so no project settings, `.mcp.json` or CLAUDE.md are found.
    public var claudeWorkingDirectory: URL { devshoutFolder.appendingPathComponent("claude-cwd", isDirectory: true) }
    /// The app's glossary (Settings → Glossary).
    public var glossaryFile: URL { devshoutFolder.appendingPathComponent("glossary.md", isDirectory: false) }
}

/// Errors from the spike's own steps (engines and Claude report theirs in their own types).
public enum SpikeError: Error, Sendable, Hashable, CustomStringConvertible {
    case missingVAD
    case unknownEngine(String)
    case unknownMode(String)
    case fileNotFound(String)
    case invalidInput(String)

    public var description: String {
        switch self {
        case .missingVAD: "Chunked transcription needs the voice activity detector, and none was given."
        case .unknownEngine(let name): "Unknown engine “\(name)”. Use parakeet or whisper."
        case .unknownMode(let name): "Unknown mode “\(name)”. Use raw, tidy or structure."
        case .fileNotFound(let path): "No such file: \(path)"
        case .invalidInput(let message): message
        }
    }
}

extension SpikeError: LocalizedError {
    public var errorDescription: String? { description }
}

/// How a clean-up failure reads in the spike tool: a sentence saying what happened and, where there is one, what to do.
public enum CleanErrorText {
    public static func describe(_ error: CleanError) -> String {
        switch error {
        case .claudeNotFound:
            return "Claude Code wasn't found. Install it (curl -fsSL https://claude.ai/install.sh | bash) and try again."
        case .notConnected:
            return "No Claude token. Run `devshout-cli connect` (or set CLAUDE_CODE_OAUTH_TOKEN to a token from `claude setup-token`)."
        case .authFailed(let message):
            let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Claude refused the token (revoked or expired). Run `claude setup-token` and `devshout-cli connect` again."
                + (said.isEmpty ? "" : " Claude said: \(said)")
        case .timedOut(let after):
            return "Claude didn't answer within \(SpikeFormat.seconds(after)), so it was stopped. Try a longer --timeout."
        case .processFailed(let exitCode, let message):
            let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return said.isEmpty ? "claude failed with exit code \(exitCode)." : "claude failed (exit code \(exitCode)): \(said)"
        case .rejectedOutput(let reason):
            return "Claude's answer was rejected: \(reason)"
        }
    }

    /// A short name for tables and notes: "timed out", "auth failed", …
    public static func shortName(_ error: CleanError) -> String {
        switch error {
        case .claudeNotFound: "claude not found"
        case .notConnected: "not connected"
        case .authFailed: "auth failed"
        case .timedOut: "timed out"
        case .processFailed: "process failed"
        case .rejectedOutput: "output rejected"
        }
    }
}
