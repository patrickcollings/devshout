import DevshoutCore
import Foundation

// Plain state types the UI renders. Foundation + DevshoutCore only (no SwiftUI, AppKit or Combine), so this file
// also type-checks on Linux. The wiring step maps the real module types (pipeline, engines, Claude connection)
// onto these. Names are deliberately specific so they don't clash with Core types of similar meaning.

// MARK: - Menu bar

/// The four looks of the menu bar icon (PLAN §7.1).
enum MenuBarIconState: String, CaseIterable, Hashable, Sendable {
    case idle, recording, working, attention

    /// Recording beats working beats attention beats idle.
    static func resolve(isRecording: Bool, isWorking: Bool, needsAttention: Bool) -> MenuBarIconState {
        if isRecording { return .recording }
        if isWorking { return .working }
        if needsAttention { return .attention }
        return .idle
    }

    /// SF Symbol for the template menu bar image.
    var symbolName: String {
        switch self {
        case .idle: "waveform"
        case .recording: "record.circle"
        case .working: "ellipsis.bubble"
        case .attention: "waveform.badge.exclamationmark"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: "devshout"
        case .recording: "devshout: recording"
        case .working: "devshout: working"
        case .attention: "devshout: needs attention"
        }
    }
}

/// How serious a status line is. Views map this to a colour and symbol.
enum StatusTone: String, Hashable, Sendable {
    case neutral, positive, warning, critical
}

/// One informational line in the menu ("Claude: connected", "Model downloading 42%").
struct MenuStatusLine: Hashable, Sendable, Identifiable {
    var text: String
    var symbolName: String
    var tone: StatusTone
    var id: String { text }
}

// MARK: - Hotkeys

/// A hotkey as shown to the user ("⌥Space"). The real recorder (KeyboardShortcuts) is added in wiring; this is
/// only for display.
struct HotkeyDisplay: Hashable, Sendable {
    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    var modifiers: Modifiers
    /// The key as printed on the keycap: "Space", "D", "F5".
    var key: String

    init(modifiers: Modifiers, key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Modifier symbols in Apple's order: ⌃⌥⇧⌘.
    var modifierSymbols: [String] {
        var symbols: [String] = []
        if modifiers.contains(.control) { symbols.append("⌃") }
        if modifiers.contains(.option) { symbols.append("⌥") }
        if modifiers.contains(.shift) { symbols.append("⇧") }
        if modifiers.contains(.command) { symbols.append("⌘") }
        return symbols
    }

    /// "⌥⇧Space"
    var text: String { modifierSymbols.joined() + key }

    static let optionSpace = HotkeyDisplay(modifiers: [.option], key: "Space")
    static let optionShiftSpace = HotkeyDisplay(modifiers: [.option, .shift], key: "Space")
    static let optionCommandSpace = HotkeyDisplay(modifiers: [.option, .command], key: "Space")
}

/// The dictation hotkeys of PLAN §7.6.
enum HotkeySlot: String, CaseIterable, Identifiable, Hashable, Sendable {
    case appDefault, tidy, structure, raw

    var id: String { rawValue }

    /// The mode this hotkey forces, or nil for "the app's default mode".
    var mode: ModeID? {
        switch self {
        case .appDefault: nil
        case .tidy: .tidy
        case .structure: .structure
        case .raw: .raw
        }
    }

    var title: String {
        switch self {
        case .appDefault: "Dictate in the app's default mode"
        case .tidy: "Dictate in Tidy"
        case .structure: "Dictate in Structure"
        case .raw: "Dictate in Raw"
        }
    }

    var defaultHotkey: HotkeyDisplay? {
        switch self {
        case .appDefault: .optionSpace
        case .structure: .optionShiftSpace
        case .raw: .optionCommandSpace
        case .tidy: nil
        }
    }
}

// MARK: - Onboarding

enum OnboardingStep: Int, CaseIterable, Identifiable, Comparable, Hashable, Sendable {
    case welcome, microphone, accessibility, speechModel, claude, hotkeys, tryIt

    var id: Int { rawValue }

    static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .speechModel: "Speech model"
        case .claude: "Claude"
        case .hotkeys: "Hotkeys"
        case .tryIt: "Try it"
        }
    }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// The raw and cleaned text of the "Try it" dictation, shown side by side.
struct TryItResult: Hashable, Sendable {
    var raw: String
    var cleaned: String?
}

// MARK: - Microphone and Accessibility

enum MicPermission: String, Hashable, Sendable {
    /// Not asked yet.
    case notDetermined
    case granted
    /// Denied or restricted: only System Settings can change it.
    case denied
}

struct InputDeviceOption: Hashable, Sendable, Identifiable {
    /// A stable identifier (the Core Audio device UID in practice).
    var id: String
    var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

// MARK: - Speech models

/// Static facts about each engine for the pickers.
struct SpeechEngineInfo: Hashable, Sendable, Identifiable {
    var id: EngineID
    var summary: String
    var detail: String
    var approximateDownloadBytes: Int64
    var isRecommended: Bool

    static func info(for engine: EngineID) -> SpeechEngineInfo {
        switch engine {
        case .parakeetV3:
            SpeechEngineInfo(id: engine,
                             summary: "Fastest. Runs on the Neural Engine.",
                             detail: "English and 24 other European languages.",
                             approximateDownloadBytes: 490_000_000,
                             isRecommended: true)
        case .whisperLargeV3Turbo:
            SpeechEngineInfo(id: engine,
                             summary: "Takes hints from your glossary.",
                             detail: "A little slower. Good with names and jargon.",
                             approximateDownloadBytes: 650_000_000,
                             isRecommended: false)
        }
    }
}

enum SpeechModelStatus: Hashable, Sendable {
    case notDownloaded
    case downloading(fraction: Double?, bytesDone: Int64?, bytesTotal: Int64?, bytesPerSecond: Double?)
    /// Compiling for this Mac or loading into memory.
    case preparing(ModelProgress.Phase)
    case ready(sizeOnDisk: Int64?)
    case failed(message: String)

    /// Maps engine progress onto a status. `bytesPerSecond` comes from the caller (it sees the progress over time).
    init(progress: ModelProgress, bytesPerSecond: Double? = nil, sizeOnDisk: Int64? = nil) {
        switch progress.phase {
        case .downloading:
            self = .downloading(fraction: progress.fraction, bytesDone: progress.bytesDone,
                                bytesTotal: progress.bytesTotal, bytesPerSecond: bytesPerSecond)
        case .compiling, .loading:
            self = .preparing(progress.phase)
        case .ready:
            self = .ready(sizeOnDisk: sizeOnDisk ?? progress.bytesTotal)
        }
    }

    var isReady: Bool { if case .ready = self { true } else { false } }

    var isDownloading: Bool { if case .downloading = self { true } else { false } }

    /// Downloading, compiling or loading.
    var isBusy: Bool {
        switch self {
        case .downloading, .preparing: true
        default: false
        }
    }

    /// Download fraction for a progress bar, when known.
    var fraction: Double? {
        switch self {
        case .downloading(let fraction, let done, let total, _):
            if let fraction { return min(max(fraction, 0), 1) }
            if let done, let total, total > 0 { return min(max(Double(done) / Double(total), 0), 1) }
            return nil
        case .ready: return 1
        default: return nil
        }
    }
}

// MARK: - Claude

struct ClaudeInstallation: Hashable, Sendable {
    var path: String
    var version: String
    /// False when the found version is older than the minimum devshout needs.
    var meetsMinimum: Bool
    var minimumVersion: String?

    init(path: String, version: String, meetsMinimum: Bool = true, minimumVersion: String? = nil) {
        self.path = path
        self.version = version
        self.meetsMinimum = meetsMinimum
        self.minimumVersion = minimumVersion
    }
}

enum ClaudeInstallStatus: Hashable, Sendable {
    case detecting
    case notFound
    case found(ClaudeInstallation)
    /// "Install for me" is running; the log is on the view model.
    case installing
    case installFailed(message: String)

    var installation: ClaudeInstallation? { if case .found(let i) = self { i } else { nil } }
}

/// The `claude setup-token` flow while it runs in its pseudo-terminal.
struct ClaudeSignInProgress: Hashable, Sendable {
    /// Set when the CLI printed a sign-in URL (the browser may not have opened).
    var signInURL: URL?
    /// The CLI is asking for the code shown in the browser.
    var needsCode: Bool
    var isSubmittingCode: Bool
    /// A problem to show, e.g. "That code didn't work. Try again."
    var message: String?

    init(signInURL: URL? = nil, needsCode: Bool = false, isSubmittingCode: Bool = false, message: String? = nil) {
        self.signInURL = signInURL
        self.needsCode = needsCode
        self.isSubmittingCode = isSubmittingCode
        self.message = message
    }
}

enum ClaudeAccountStatus: Hashable, Sendable {
    /// Not checked yet.
    case unknown
    case notConnected
    case signingIn(ClaudeSignInProgress)
    /// A token is in the Keychain. Only its creation date reaches the UI, never the token.
    case connected(tokenCreatedAt: Date)
    /// A run failed on authentication, or the token expired.
    case needsReconnect(reason: String)

    var isConnected: Bool { if case .connected = self { true } else { false } }
    var signIn: ClaudeSignInProgress? { if case .signingIn(let p) = self { p } else { nil } }
}

enum ClaudeTestStatus: Hashable, Sendable {
    case idle
    case running
    case succeeded(elapsed: TimeInterval, at: Date)
    case failed(message: String)
}

/// When a `claude setup-token` token runs out: one year after it was made, with a warning 30 days before.
struct TokenExpiry: Hashable, Sendable {
    static let warningDays = 30

    var createdAt: Date
    var expiresAt: Date

    init(createdAt: Date, calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.createdAt = createdAt
        self.expiresAt = calendar.date(byAdding: .year, value: 1, to: createdAt)
            ?? createdAt.addingTimeInterval(365 * 24 * 3600)
    }

    /// Whole days left, rounded down; 0 on the last day, negative once expired.
    func daysRemaining(now: Date) -> Int {
        let seconds = expiresAt.timeIntervalSince(now)
        return Int((seconds / 86_400).rounded(.down))
    }

    func isExpired(now: Date) -> Bool { now >= expiresAt }

    func needsWarning(now: Date) -> Bool { daysRemaining(now: now) < Self.warningDays }
}

// MARK: - Settings values

struct GeneralPreferences: Hashable, Sendable {
    enum HotkeyBehaviour: String, CaseIterable, Identifiable, Hashable, Sendable {
        case tapOrHold, toggleOnly, holdOnly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .tapOrHold: "Tap to toggle, hold to talk"
            case .toggleOnly: "Toggle only"
            case .holdOnly: "Hold to talk only"
            }
        }
    }

    enum PasteMethod: String, CaseIterable, Identifiable, Hashable, Sendable {
        case commandV, accessibility
        var id: String { rawValue }
        var title: String {
            switch self {
            case .commandV: "Press ⌘V"
            case .accessibility: "Type via Accessibility"
            }
        }
    }

    var launchAtLogin: Bool = false
    var hotkeyBehaviour: HotkeyBehaviour = .tapOrHold
    var playsSounds: Bool = true
    var pasteMethod: PasteMethod = .commandV
    var showsLivePreview: Bool = true
}

/// The Claude model aliases offered per mode.
enum ClaudeModelOption: String, CaseIterable, Identifiable, Hashable, Sendable {
    case haiku, sonnet, opus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .haiku: "Haiku"
        case .sonnet: "Sonnet"
        case .opus: "Opus"
        }
    }

    var detail: String {
        switch self {
        case .haiku: "Fastest. Best for Tidy."
        case .sonnet: "Balanced. Best for Structure."
        case .opus: "Most capable, slowest."
        }
    }

    /// The option for a `ModeConfig.claudeModel` value, or nil for a full model name.
    init?(alias: String) {
        self.init(rawValue: alias.lowercased())
    }

    /// "Haiku" for an alias, the name itself otherwise.
    static func displayName(for model: String) -> String {
        ClaudeModelOption(alias: model)?.title ?? model
    }
}

/// A per-app default mode (Settings → Apps).
struct AppModeRule: Hashable, Sendable, Identifiable {
    var bundleID: String
    var name: String
    var mode: ModeID
    var id: String { bundleID }

    init(bundleID: String, name: String, mode: ModeID) {
        self.bundleID = bundleID
        self.name = name
        self.mode = mode
    }

    /// Pre-filled suggestions (PLAN §7.4).
    static let suggestions: [AppModeRule] = [
        AppModeRule(bundleID: "com.apple.Terminal", name: "Terminal", mode: .structure),
        AppModeRule(bundleID: "com.googlecode.iterm2", name: "iTerm", mode: .structure),
        AppModeRule(bundleID: "com.mitchellh.ghostty", name: "Ghostty", mode: .structure),
        AppModeRule(bundleID: "dev.warp.Warp-Stable", name: "Warp", mode: .structure),
        AppModeRule(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", mode: .structure),
        AppModeRule(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor", mode: .structure),
        AppModeRule(bundleID: "com.anthropic.claudefordesktop", name: "Claude", mode: .structure),
        AppModeRule(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", mode: .tidy),
        AppModeRule(bundleID: "com.apple.mail", name: "Mail", mode: .tidy),
        AppModeRule(bundleID: "com.apple.Notes", name: "Notes", mode: .tidy),
    ]
}

/// An app the user can add a rule for (running apps, or one picked from /Applications).
struct AppCandidate: Hashable, Sendable, Identifiable {
    var bundleID: String
    var name: String
    /// The .app bundle, for its icon.
    var url: URL?
    var id: String { bundleID }

    init(bundleID: String, name: String, url: URL? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.url = url
    }
}

/// What the injected glossary parser reports about the text in the editor.
struct GlossaryTermCounts: Hashable, Sendable {
    var terms: Int
    var people: Int
    var patterns: Int
    /// Total `heard:` entries across all sections.
    var mishearings: Int

    init(terms: Int = 0, people: Int = 0, patterns: Int = 0, mishearings: Int = 0) {
        self.terms = terms
        self.people = people
        self.patterns = patterns
        self.mishearings = mishearings
    }

    static let empty = GlossaryTermCounts()
}

enum AudioRetention: String, CaseIterable, Identifiable, Hashable, Sendable {
    case days7, days30, days90, forever

    var id: String { rawValue }

    /// nil = keep forever.
    var days: Int? {
        switch self {
        case .days7: 7
        case .days30: 30
        case .days90: 90
        case .forever: nil
        }
    }

    var title: String {
        switch self {
        case .days7: "7 days"
        case .days30: "30 days"
        case .days90: "90 days"
        case .forever: "Forever"
        }
    }
}

// MARK: - History

/// What the History detail pane's Play button is doing.
enum HistoryPlayback: Hashable, Sendable {
    case idle
    /// This recording's audio is playing.
    case playing(UUID)
    /// This recording's audio couldn't be played; `message` says why ("The audio file is no longer there").
    case unavailable(UUID, message: String)
}

/// A recording's transcript being sent to Claude again from History ("Re-run").
enum HistoryRerunState: Hashable, Sendable {
    /// `model` is the `ModeConfig.claudeModel` value ("haiku").
    case running(mode: ModeID, model: String)
    /// `message` is ready to show ("Claude isn't connected. …").
    case failed(mode: ModeID, message: String)
}

/// One titled text in the History detail pane: a clean version, what was pasted, or the transcript as heard.
struct HistorySection: Hashable, Sendable, Identifiable {
    var id: String
    /// "Tidy · Haiku · 10 Nov 2026, 14:02", "Pasted into Slack", "As heard, before Claude".
    var title: String
    var text: String
    /// A line under the text (the clean-up's warnings), when there is one.
    var note: String? = nil
}

// MARK: - Recording pill

/// What the overlay pill is showing (PLAN §7.3). Showing and hiding the panel is up to the caller.
enum PillPhase: Hashable, Sendable {
    case recording
    /// Recording stopped; the last chunk is being transcribed. `remaining` = seconds of audio still to do.
    case transcribing(remaining: TimeInterval?)
    /// Claude is cleaning up. `model` is the `ModeConfig.claudeModel` value ("haiku").
    case cleaning(model: String)
    case done(DeliveryOutcome)
    /// Raw text was delivered instead of the cleaned text; `reason` says why ("Claude timed out").
    case fallback(reason: String, outcome: DeliveryOutcome)
    /// Nothing could be delivered. The audio is saved.
    case error(message: String)

    var isRecording: Bool { self == .recording }
}
