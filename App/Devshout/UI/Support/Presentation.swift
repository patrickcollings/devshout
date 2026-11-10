import DevshoutCore
import Foundation

// Text the UI shows for each state. Foundation + DevshoutCore only, so it type-checks on Linux; keeping the
// wording here (not in views) means views stay dumb and the copy is in one place. British English throughout.

enum UIFormat {
    /// "03:12", or "1:03:12" past an hour.
    static func timer(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    /// "2.1 s"
    static func seconds(_ seconds: TimeInterval) -> String {
        String(format: "%.1f s", seconds)
    }

    /// "632 MB"
    static func bytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    /// "42%"
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }

    /// "12.4 MB/s"
    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// "About 3 min left", "Less than a minute left"
    static func timeLeft(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "Less than a minute left" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "About \(minutes) min left" }
        let hours = Double(seconds) / 3600
        return String(format: "About %.1f h left", hours)
    }

    /// "10 Nov 2027"
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// "14:02"
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func plural(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count) " + (count == 1 ? singular : (plural ?? singular + "s"))
    }
}

// MARK: - Speech model

extension SpeechModelStatus {
    /// What the long first load is, in plain words.
    static let optimisingExplanation = "The first time a speech model is used on this Mac, macOS converts it to run on the chip's Neural Engine. It happens once per model (and again after a macOS update): about 10 minutes for Whisper, under a minute for Parakeet. You can't dictate until it finishes."

    /// One line for Settings and onboarding.
    var summary: String {
        switch self {
        case .notDownloaded:
            return "Not downloaded"
        case .downloading(_, let done, let total, let speed):
            var parts: [String] = []
            if let fraction { parts.append("Downloading \(UIFormat.percent(fraction))") } else { parts.append("Downloading…") }
            if let done, let total, total > 0 { parts.append("\(UIFormat.bytes(done)) of \(UIFormat.bytes(total))") }
            if let speed, speed > 0 {
                parts.append(UIFormat.speed(speed))
                if let done, let total, total > done {
                    parts.append(UIFormat.timeLeft(Double(total - done) / speed))
                }
            }
            return parts.joined(separator: " · ")
        case .preparing(let phase):
            return phase == .compiling ? "Getting ready for this Mac…" : "Loading…"
        case .ready(let size):
            if let size { return "Ready · \(UIFormat.bytes(size))" }
            return "Ready"
        case .failed(let message):
            return "Download failed: \(message)"
        }
    }

    /// The menu line, or nil when there is nothing worth saying.
    var menuLine: MenuStatusLine? {
        switch self {
        case .notDownloaded:
            return MenuStatusLine(text: "Speech model not downloaded", symbolName: "arrow.down.circle", tone: .warning)
        case .downloading:
            let text = fraction.map { "Model downloading \(UIFormat.percent($0))" } ?? "Model downloading…"
            return MenuStatusLine(text: text, symbolName: "arrow.down.circle", tone: .neutral)
        case .preparing:
            return MenuStatusLine(text: "Model loading…", symbolName: "hourglass", tone: .neutral)
        case .ready:
            return nil
        case .failed:
            return MenuStatusLine(text: "Model download failed", symbolName: "exclamationmark.triangle", tone: .critical)
        }
    }
}

// MARK: - Claude

extension ClaudeInstallStatus {
    var summary: String {
        switch self {
        case .detecting: "Looking for Claude Code…"
        case .notFound: "Claude Code isn't installed"
        case .found(let i) where !i.meetsMinimum:
            "Claude Code \(i.version) is too old" + (i.minimumVersion.map { " (needs \($0) or later)" } ?? "")
        case .found(let i): "Claude Code \(i.version)"
        case .installing: "Installing Claude Code…"
        case .installFailed(let message): "Install failed: \(message)"
        }
    }

    var tone: StatusTone {
        switch self {
        case .detecting, .installing: .neutral
        case .found(let i): i.meetsMinimum ? .positive : .warning
        case .notFound: .warning
        case .installFailed: .critical
        }
    }
}

extension TokenExpiry {
    /// "today", "in 1 day", "in 12 days"
    static func inDays(_ days: Int) -> String {
        days <= 0 ? "today" : "in \(UIFormat.plural(days, "day"))"
    }
}

extension ClaudeAccountStatus {
    /// "Connected", "Connected · expires in 12 days", "Not connected", …
    func summary(now: Date) -> String {
        switch self {
        case .unknown: return "Checking…"
        case .notConnected: return "Not connected"
        case .signingIn: return "Signing in…"
        case .connected(let createdAt):
            let expiry = TokenExpiry(createdAt: createdAt)
            let days = expiry.daysRemaining(now: now)
            if expiry.isExpired(now: now) { return "Token expired: reconnect" }
            if expiry.needsWarning(now: now) { return "Connected · token expires \(TokenExpiry.inDays(days))" }
            return "Connected"
        case .needsReconnect: return "Needs reconnecting"
        }
    }

    func tone(now: Date) -> StatusTone {
        switch self {
        case .unknown, .signingIn: return .neutral
        case .notConnected: return .warning
        case .needsReconnect: return .critical
        case .connected(let createdAt):
            let expiry = TokenExpiry(createdAt: createdAt)
            if expiry.isExpired(now: now) { return .critical }
            return expiry.needsWarning(now: now) ? .warning : .positive
        }
    }

    /// Whether the menu bar icon should show its attention badge.
    func needsAttention(now: Date) -> Bool {
        switch tone(now: now) {
        case .warning, .critical: true
        default: false
        }
    }

    func menuLine(now: Date) -> MenuStatusLine {
        let tone = tone(now: now)
        let text: String
        switch self {
        case .unknown: text = "Claude: checking…"
        case .notConnected: text = "Claude: not connected"
        case .signingIn: text = "Claude: signing in…"
        case .needsReconnect: text = "Claude: reconnect needed"
        case .connected(let createdAt):
            let expiry = TokenExpiry(createdAt: createdAt)
            let days = expiry.daysRemaining(now: now)
            if expiry.isExpired(now: now) { text = "Claude: token expired" }
            else if expiry.needsWarning(now: now) { text = "Claude: token expires \(TokenExpiry.inDays(days))" }
            else { text = "Claude: connected" }
        }
        let symbol: String
        switch tone {
        case .positive: symbol = "checkmark.circle"
        case .neutral: symbol = "ellipsis.circle"
        case .warning: symbol = "exclamationmark.circle"
        case .critical: symbol = "exclamationmark.triangle"
        }
        return MenuStatusLine(text: text, symbolName: symbol, tone: tone)
    }
}

extension ClaudeTestStatus {
    var summary: String? {
        switch self {
        case .idle: nil
        case .running: "Testing…"
        case .succeeded(let elapsed, let at): "Worked in \(UIFormat.seconds(elapsed)) at \(UIFormat.time(at))"
        case .failed(let message): "Failed: \(message)"
        }
    }
}

// MARK: - Menu

enum MenuStatus {
    /// The status lines shown in the menu, most important first. Empty lines are left out; when all is well the
    /// only line is the Claude one.
    static func lines(account: ClaudeAccountStatus, claudeSkipped: Bool, model: SpeechModelStatus,
                      microphone: MicPermission, accessibilityTrusted: Bool, now: Date) -> [MenuStatusLine] {
        var lines: [MenuStatusLine] = []
        if microphone != .granted {
            lines.append(MenuStatusLine(text: "Microphone access needed", symbolName: "mic.slash", tone: .critical))
        }
        if !accessibilityTrusted {
            lines.append(MenuStatusLine(text: "Accessibility access needed to paste",
                                        symbolName: "hand.raised", tone: .warning))
        }
        if let line = model.menuLine { lines.append(line) }
        if claudeSkipped, case .notConnected = account {
            lines.append(MenuStatusLine(text: "Claude: not connected (Raw only)", symbolName: "circle.dashed", tone: .neutral))
        } else {
            lines.append(account.menuLine(now: now))
        }
        return lines
    }

    static func needsAttention(account: ClaudeAccountStatus, claudeSkipped: Bool, model: SpeechModelStatus,
                               microphone: MicPermission, accessibilityTrusted: Bool, now: Date) -> Bool {
        if microphone != .granted || !accessibilityTrusted { return true }
        switch model {
        case .failed, .notDownloaded: return true
        default: break
        }
        if claudeSkipped, case .notConnected = account { return false }
        return account.needsAttention(now: now)
    }
}

// MARK: - Recording pill

extension PillPhase {
    /// The main line of the pill (the timer and waveform take the place of a title while recording).
    func title(mode: ModeID) -> String {
        switch self {
        case .recording:
            return mode.displayName
        case .transcribing(let remaining):
            if let remaining, remaining >= 1 { return "Transcribing the last \(Int(remaining.rounded())) s…" }
            return "Transcribing…"
        case .cleaning(let model):
            let verb = mode == .structure ? "Structuring" : "Tidying"
            return model.isEmpty ? "\(verb)…" : "\(verb) with \(ClaudeModelOption.displayName(for: model))…"
        case .done(.pasted(let appName)):
            if let appName, !appName.isEmpty { return "Pasted into \(appName)" }
            return "Pasted"
        case .done(.copiedOnly):
            return "Copied: press ⌘V"
        case .fallback(let reason, .pasted):
            return "Pasted raw: \(reason)"
        case .fallback(_, .copiedOnly):
            return "Copied raw: press ⌘V"
        case .done(.failed(let reason)), .fallback(_, .failed(let reason)):
            return reason
        case .error(let message):
            return message
        }
    }

    /// A smaller second line, when there is one to show besides the live transcript.
    var subtitle: String? {
        switch self {
        case .done(.copiedOnly(let reason)): reason
        case .fallback(let reason, .copiedOnly(let copyReason)): "\(reason). \(copyReason)"
        default: nil
        }
    }

    var tone: StatusTone {
        switch self {
        case .recording, .transcribing, .cleaning: .neutral
        case .done(.pasted): .positive
        case .done(.copiedOnly), .fallback: .warning
        case .done(.failed), .error: .critical
        }
    }

    var symbolName: String {
        switch self {
        case .recording: "record.circle"
        case .transcribing: "waveform"
        case .cleaning: "sparkles"
        case .done(.pasted): "checkmark.circle.fill"
        case .done(.copiedOnly): "doc.on.clipboard"
        case .done(.failed): "xmark.circle.fill"
        case .fallback: "exclamationmark.circle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    /// Whether the second line (live transcript) may show in this phase.
    var allowsLiveText: Bool {
        switch self {
        case .recording, .transcribing: true
        default: false
        }
    }
}

// MARK: - Glossary

extension GlossaryTermCounts {
    /// "132 terms · 18 people · 4 patterns · 210 mishearings"
    var summary: String {
        [UIFormat.plural(terms, "term"),
         UIFormat.plural(people, "person", "people"),
         UIFormat.plural(patterns, "pattern"),
         UIFormat.plural(mishearings, "mishearing")].joined(separator: " · ")
    }
}

// MARK: - History

/// What the History tab says about a recording.
enum HistoryText {
    /// The text to show first and to copy: what was pasted, else the cleaned text, else the transcript.
    static func bestText(for recording: Recording) -> String? {
        for candidate in [recording.deliveredText, recording.latestVersion?.text, recording.transcript] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return nil
    }

    static func bestTitle(for recording: Recording) -> String {
        guard recording.deliveredText != nil, let delivered = recording.delivered else { return "Transcript (not pasted)" }
        switch delivered.method {
        case .pasted: return delivered.appName.map { "Pasted into \($0)" } ?? "Pasted"
        case .copiedOnly: return "Copied to the clipboard"
        case .failed: return "Not pasted"
        }
    }

    /// The texts the detail pane shows, top to bottom: every clean version, newest first (so a re-run comes
    /// first), then what was pasted when that is none of them, then the transcript as heard when it differs from
    /// all of those. A dictation that was never re-run reads as before: "Pasted into Slack", then "As heard".
    static func sections(for recording: Recording) -> [HistorySection] {
        func trimmed(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        let delivered = trimmed(recording.deliveredText)
        let versions = recording.versions.enumerated()
            .filter { trimmed($0.element.text) != nil }
            .sorted { a, b in
                a.element.createdAt != b.element.createdAt ? a.element.createdAt > b.element.createdAt : a.offset > b.offset
            }
            .map(\.element)
        // The version that was pasted is the oldest one with the pasted text (a re-run can give the same text).
        let deliveredVersion = versions.last { trimmed($0.text) == delivered && delivered != nil }
        let isOnlyVersion = versions.count == 1 && deliveredVersion != nil

        var sections: [HistorySection] = []
        for version in versions {
            var title = isOnlyVersion ? bestTitle(for: recording) : versionTitle(version)
            if !isOnlyVersion, version.id == deliveredVersion?.id, let note = deliveredNote(for: recording) {
                title += " · " + note
            }
            sections.append(HistorySection(id: "version-\(version.id.uuidString)", title: title,
                                           text: trimmed(version.text) ?? "",
                                           note: version.warnings.isEmpty ? nil : version.warnings.joined(separator: " · ")))
        }
        if let delivered, deliveredVersion == nil {
            sections.append(HistorySection(id: "delivered", title: bestTitle(for: recording), text: delivered))
        }
        if let transcript = trimmed(recording.transcript) {
            if sections.isEmpty {
                sections.append(HistorySection(id: "transcript", title: bestTitle(for: recording), text: transcript))
            } else if !sections.contains(where: { $0.text == transcript }) {
                sections.append(HistorySection(id: "heard", title: "As heard, before Claude", text: transcript))
            }
        }
        return sections
    }

    /// "Structure · Sonnet · 10 Nov 2026, 14:02"
    static func versionTitle(_ version: CleanVersion) -> String {
        var parts = [version.mode.displayName]
        if !version.model.isEmpty { parts.append(ClaudeModelOption.displayName(for: version.model)) }
        parts.append("\(UIFormat.day(version.createdAt)), \(UIFormat.time(version.createdAt))")
        return parts.joined(separator: " · ")
    }

    /// After the title of the version that was delivered: "pasted into Slack".
    static func deliveredNote(for recording: Recording) -> String? {
        guard let delivered = recording.delivered else { return nil }
        switch delivered.method {
        case .pasted: return delivered.appName.map { "pasted into \($0)" } ?? "pasted"
        case .copiedOnly: return "copied to the clipboard"
        case .failed: return "not pasted"
        }
    }

    // Re-running through Claude.

    static let rerunHelp = "Send the transcript to Claude again in another mode. Nothing is pasted: the result is added here to read and copy."

    /// "Claude (Sonnet) is structuring…"
    static func rerunProgress(mode: ModeID, model: String) -> String {
        let claude = model.isEmpty ? "Claude" : "Claude (\(ClaudeModelOption.displayName(for: model)))"
        return "\(claude) is \(mode == .structure ? "structuring" : "tidying")…"
    }

    static func rerunFailed(mode: ModeID, _ error: CleanError) -> String {
        "Not re-run as \(mode.displayName). " + rerunFailure(error)
    }

    private static func rerunFailure(_ error: CleanError) -> String {
        switch error {
        case .claudeNotFound: return "Claude Code wasn't found. Install it in Settings → Claude."
        case .notConnected: return "Claude isn't connected. Connect it in Settings → Claude."
        case .authFailed: return "Claude didn't accept the token. Reconnect in Settings → Claude."
        case .timedOut(let after):
            return "Claude timed out after \(Int(after.rounded())) s. The limit is in Settings → Modes."
        case .processFailed(let code, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Claude failed (exit code \(code))." : "Claude failed: \(detail)"
        case .rejectedOutput(let reason): return "Claude's output was rejected: \(reason)."
        }
    }

    static func rerunNothingToSend(mode: ModeID) -> String {
        "Not re-run as \(mode.displayName). This recording has no transcript to send to Claude."
    }

    /// Claude answered, but record.json couldn't be read or written.
    static func rerunNotSaved(mode: ModeID, detail: String) -> String {
        "Re-run as \(mode.displayName), but the result couldn't be saved: \(detail)"
    }

    static func snippet(for recording: Recording) -> String {
        bestText(for: recording) ?? recording.errorMessage ?? "No text"
    }

    /// "00:07 · Whisper large-v3-turbo · took 3.2 s"
    static func facts(for recording: Recording) -> String {
        var parts = [UIFormat.timer(recording.duration)]
        if let engine = recording.engine { parts.append(engine.displayName) }
        if let total = recording.timings.total { parts.append("took \(UIFormat.seconds(total))") }
        return parts.joined(separator: " · ")
    }

    // Playing the audio.

    /// On the (disabled) Play button once retention has deleted audio.wav.
    static let audioDeletedLabel = "Audio deleted"

    static func audioDeletedHelp(for recording: Recording) -> String {
        guard let date = recording.audioDeletedAt else { return "The audio has been deleted. The text is kept." }
        return "The audio was deleted on \(UIFormat.day(date)), as set in Settings → Privacy. The text is kept."
    }

    /// The record says there is audio, but audio.wav isn't in the recording's folder.
    static let audioMissing = "The audio file is no longer there."
    static let audioUnplayable = "The audio couldn't be played."
    static let cannotPlayWhileDictating = "Can't play while a dictation is recording."

    /// Under the search field when the search finds nothing.
    static func noMatches(for search: String) -> String {
        "No dictations contain “\(search.trimmingCharacters(in: .whitespacesAndNewlines))”."
    }
}
