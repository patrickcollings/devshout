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

// MARK: - Voice calibration

/// The wording of "Calibrate your voice". The recommendation sentence itself comes from Core
/// (`CalibrationRecommendation.summary`), so `devshout-cli calibrate` prints the same words.
enum CalibrationCopy {
    static let windowTitle = "Calibrate Your Voice"
    static let openButton = "Calibrate Your Voice…"

    // Settings → Transcription
    static let settingsExplanation = "Read ten short sentences aloud and devshout measures how well each speech model understands you, recommends the better one, and learns the words it keeps getting wrong."

    /// "Last calibrated 10 Nov 2026: Whisper 96%, Parakeet 89%"
    static func lastResult(_ result: CalibrationLastResult) -> String {
        let scores = result.accuracySummary.isEmpty ? "" : ": \(result.accuracySummary)"
        return "Last calibrated \(UIFormat.day(result.date))\(scores)"
    }

    // Onboarding → Try it
    static let onboardingOffer = "Not quite getting your voice? Calibrating takes about three minutes, and you can do it any time from Settings → Transcription."

    // Introduction
    static let introTitle = "Calibrate your voice"
    static let introMessage = "Dictation works better for some voices and accents than others. Read a short script aloud and devshout will measure how well it understands you."
    static let introSteps = [
        "Read ten sentences, one at a time. It takes two to three minutes.",
        "Each speech model transcribes your recordings and is scored against what you read.",
        "You see which model understood you better, and which of your glossary terms it mishears, so they can be fixed from now on.",
    ]
    static let introPrivacy = "The recordings stay on this Mac."
    static let beginButton = "Start"

    /// Which models will be measured, or why none can be.
    static func introEngines(ready: [EngineID], missing: [EngineID]) -> (text: String, tone: StatusTone) {
        if ready.isEmpty {
            return ("No speech model is ready yet. Download one in Settings → Transcription first.", .warning)
        }
        if let other = missing.first, ready.count == 1 {
            return ("Only \(ready[0].shortName) is downloaded, so only it will be measured. Download \(other.shortName) in Settings → Transcription to compare the two.", .neutral)
        }
        return ("\(CalibrationReport.engineList(ready)) will be compared.", .positive)
    }

    static let microphoneDenied = "Microphone access is off. Allow devshout in System Settings → Privacy & Security → Microphone."

    // Writing the script
    static let preparingTitle = "Writing sentences that use your glossary terms…"
    static let preparingDetail = "Claude is writing them. This takes a few seconds."
    static let useBuiltInButton = "Use Built-in Sentences"

    // Reading
    static func sentenceCounter(index: Int, count: Int) -> String { "Sentence \(index + 1) of \(count)" }
    static let readingHint = "Press Record, read the sentence aloud at your normal pace, then press Stop."
    static let recordingHint = "Recording. Read the sentence, then press Stop."
    static let startingHint = "Starting the microphone…"
    static let stoppingHint = "Saving…"
    static func recordedHint(_ duration: TimeInterval) -> String {
        "Recorded (\(UIFormat.seconds(duration))). Record it again if you stumbled, or carry on."
    }
    static let recordButton = "Record"
    static let stopButton = "Stop"
    static let recordAgainButton = "Record Again"
    static let nextButton = "Next"
    static let finishButton = "Finish"
    static let backButton = "Back"

    static let dictationInProgress = "A dictation is in progress. Wait for it to finish, then try again."
    static let stillStopping = "The last measurement is still stopping. Try again in a moment."
    static let takeTooShort = "That was too short to use. Press Record and read the whole sentence."
    static let takeTooLong = "Recording stopped after a minute. Record the sentence again if it was cut off."
    static func couldNotRecord(_ reason: String) -> String { "Couldn't record: \(reason)" }

    /// What the dictation pill says when a hotkey is pressed during calibration.
    static let dictationBlockedTitle = "Voice calibration is running"
    static let dictationBlockedDetail = "Finish or close the calibration window, then dictate."

    // Analysing
    static let analysingTitle = "Measuring how well you were understood…"
    static func analysing(_ progress: CalibrationProgressState) -> String {
        guard let engine = progress.engine else { return "Getting ready…" }
        if progress.isLoading {
            return "Loading \(engine.shortName). The first time can take a few minutes."
        }
        return "\(engine.shortName): sentence \(min(progress.done + 1, max(progress.total, 1))) of \(progress.total)"
    }
    static let cancelButton = "Cancel"

    // Results
    static let resultsTitle = "How well you were understood"
    static let columnEngine = "Speech model"
    static let columnAccuracy = "Words right"
    static let columnTerms = "Glossary terms right"
    static let columnSpeed = "Time per minute of speech"
    static let inUse = "In use"

    static func accuracy(_ score: CalibrationEngineScore) -> String { CalibrationReport.accuracy(score) }

    static func terms(_ score: CalibrationEngineScore) -> String {
        guard let rate = score.termHitRate else { return "None in the script" }
        return "\(score.termHits) of \(score.termCount) (\(CalibrationRecommendation.percent(rate)))"
    }

    static func speed(_ score: CalibrationEngineScore) -> String {
        guard let seconds = score.secondsPerMinute else { return "Not measured" }
        return String(format: "%.1f s", seconds)
    }

    static func failure(_ failure: CalibrationEngineFailure) -> String {
        "\(failure.engine.shortName) couldn't be measured: \(failure.message)"
    }

    static func switchButton(_ engine: EngineID) -> String { "Use \(engine.shortName)" }
    static func nowUsing(_ engine: EngineID) -> String { "devshout is using \(engine.shortName)." }

    static let correctionsTitle = "Words to fix from now on"
    static let correctionsExplanation = "These glossary terms came out as something else. Ticked ones are added to your glossary as known mishearings, and replaced in every dictation."
    static let noCorrections = "Every glossary term in the script came out right, or was already a known mishearing."

    /// "heard “causia” → CORSIA"
    static func correctionHeard(_ correction: LearnedCorrection) -> String { "heard “\(correction.heard)”" }

    static func correctionDetail(_ correction: LearnedCorrection) -> String {
        var detail = CalibrationReport.engineList(correction.engines)
        if correction.count > 1 { detail += ", \(correction.count) times" }
        return detail
    }

    static func ordinaryWarning(_ correction: LearnedCorrection) -> String {
        let words = correction.heard.contains(" ") ? "are ordinary words" : "is an ordinary word"
        return "“\(correction.heard)” \(words), so replacing it everywhere would also change sentences where you really said it."
    }

    static let notesTitle = "Notes for Claude"
    static let notesExplanation = "These ordinary words were mixed up. They are never replaced automatically, but a ticked note is added to your glossary's Style section, which Claude reads when it tidies a dictation."

    /// "“work” came out as “walk”"
    static func note(_ note: LearnedStyleNote) -> String { "“\(note.said)” came out as “\(note.written)”" }

    static let applyButton = "Add to Glossary"
    static let added = "Added"

    static func applied(corrections: Int, notes: Int) -> String {
        var parts: [String] = []
        if corrections > 0 { parts.append(UIFormat.plural(corrections, "mishearing")) }
        if notes > 0 { parts.append(UIFormat.plural(notes, "note")) }
        return "Added \(parts.joined(separator: " and ")) to your glossary."
    }

    static func couldNotApply(_ reason: String) -> String { "Couldn't change the glossary: \(reason)" }

    static let doneButton = "Done"
    static let closeButton = "Close"
    static let tryAgainButton = "Try Again"
    static let failedTitle = "Calibration couldn't finish"
    static let noEngineReady = "No speech model is ready. Download one in Settings → Transcription, then try again."
    static let nothingRecorded = "No sentence was recorded."
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
