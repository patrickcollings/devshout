// View models shared by onboarding, Settings and the menu: microphone, Accessibility, speech models, Claude and
// hotkeys. Each is a concrete @MainActor ObservableObject: the wiring step sets its @Published state from the real
// modules and passes closures (`Actions`) for what the buttons do. Nothing here talks to the system directly.
//
// Pattern for values the user edits (device, engine, …): the property's didSet calls the matching action. To set
// such a value from outside without it echoing back, wrap the assignment in `sync { … }`.
//
// Unsure on macOS (not compiled here): nothing exotic; Combine and SwiftUI.Binding only.

import Combine
import DevshoutCore
import Foundation
import SwiftUI

// MARK: - Audio level

/// Live input level for meters and the pill's waveform. Kept separate so ~30 updates a second only redraw the meter.
@MainActor
final class AudioLevelViewModel: ObservableObject {
    static let historyLength = 40

    /// Smoothed level, 0...1.
    @Published private(set) var level: Float = 0
    /// The last `historyLength` levels, oldest first.
    @Published private(set) var history: [Float]

    init(history: [Float] = []) {
        let padded = Array(repeating: Float(0), count: max(0, Self.historyLength - history.count)) + history
        self.history = Array(padded.suffix(Self.historyLength))
        self.level = history.last ?? 0
    }

    /// Call 20–30 times a second with a level in 0...1 (see `normalised(dBFS:)`).
    func push(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        // Fast attack, slower release, so the meter feels alive but not jittery.
        level = clamped > level ? clamped : level * 0.7 + clamped * 0.3
        var next = history
        next.append(clamped)
        if next.count > Self.historyLength { next.removeFirst(next.count - Self.historyLength) }
        history = next
    }

    func reset() {
        level = 0
        history = Array(repeating: 0, count: Self.historyLength)
    }

    /// Maps -60…0 dBFS onto 0…1.
    nonisolated static func normalised(dBFS: Float) -> Float {
        guard dBFS.isFinite else { return 0 }
        return min(max((dBFS + 60) / 60, 0), 1)
    }
}

// MARK: - Microphone

@MainActor
final class MicrophoneViewModel: ObservableObject {
    struct Actions {
        /// Ask for microphone access (`AVCaptureDevice.requestAccess`).
        var requestAccess: @MainActor () -> Void = {}
        /// Open System Settings → Privacy & Security → Microphone.
        var openPrivacySettings: @MainActor () -> Void = {}
        /// Start feeding `level` (a meter is on screen). Called once however many meters are showing.
        var startLevelMonitoring: @MainActor () -> Void = {}
        var stopLevelMonitoring: @MainActor () -> Void = {}
        /// nil = the system default input.
        var selectDevice: @MainActor (String?) -> Void = { _ in }
    }

    @Published var permission: MicPermission {
        didSet { updateMonitoring() }
    }
    @Published var devices: [InputDeviceOption]
    /// nil = the system default input.
    @Published var selectedDeviceID: String? {
        didSet { if !isSyncing, selectedDeviceID != oldValue { actions.selectDevice(selectedDeviceID) } }
    }
    let level: AudioLevelViewModel
    var actions: Actions

    private var isSyncing = false
    /// How many views want the meter running; it runs while this is above zero and access is granted.
    private var monitoringRequests = 0
    private var isMonitoring = false

    init(permission: MicPermission = .notDetermined, devices: [InputDeviceOption] = [],
         selectedDeviceID: String? = nil, level: AudioLevelViewModel? = nil,
         actions: Actions = Actions()) {
        self.permission = permission
        self.devices = devices
        self.selectedDeviceID = selectedDeviceID
        self.level = level ?? AudioLevelViewModel()
        self.actions = actions
    }

    /// Set state without calling `actions`.
    func sync(_ change: () -> Void) {
        isSyncing = true
        change()
        isSyncing = false
    }

    func requestAccess() { actions.requestAccess() }
    func openPrivacySettings() { actions.openPrivacySettings() }
    /// Balanced with `stopLevelMonitoring()`. Several views (onboarding, Settings) may ask at once; the action
    /// runs once, and only while access is granted (it starts by itself when access arrives).
    func startLevelMonitoring() {
        monitoringRequests += 1
        updateMonitoring()
    }

    func stopLevelMonitoring() {
        monitoringRequests = max(0, monitoringRequests - 1)
        updateMonitoring()
    }

    private func updateMonitoring() {
        let shouldMonitor = monitoringRequests > 0 && permission == .granted
        guard shouldMonitor != isMonitoring else { return }
        isMonitoring = shouldMonitor
        if shouldMonitor {
            actions.startLevelMonitoring()
        } else {
            actions.stopLevelMonitoring()
            level.reset()
        }
    }
}

// MARK: - Accessibility

@MainActor
final class AccessibilityViewModel: ObservableObject {
    struct Actions {
        /// `AXIsProcessTrustedWithOptions` with the prompt option, which also adds devshout to the list.
        var requestTrust: @MainActor () -> Void = {}
        /// Open System Settings → Privacy & Security → Accessibility.
        var openSettings: @MainActor () -> Void = {}
        /// Reveal devshout.app in Finder, for removing and re-adding it.
        var revealAppInFinder: @MainActor () -> Void = {}
    }

    /// Kept up to date by polling `AXIsProcessTrusted()` (about once a second while it matters).
    @Published var isTrusted: Bool
    /// Set once the user has opened System Settings from here; shows the "remove and re-add" hint.
    @Published private(set) var hasOpenedSettings = false
    var actions: Actions

    init(isTrusted: Bool = false, actions: Actions = Actions()) {
        self.isTrusted = isTrusted
        self.actions = actions
    }

    var showsStaleEntryHint: Bool { hasOpenedSettings && !isTrusted }

    func openSettings() {
        actions.requestTrust()
        actions.openSettings()
        hasOpenedSettings = true
    }

    func revealAppInFinder() { actions.revealAppInFinder() }
}

// MARK: - Speech models

@MainActor
final class SpeechEngineViewModel: ObservableObject {
    struct Actions {
        var selectEngine: @MainActor (EngineID) -> Void = { _ in }
        /// Start (or resume) the download and preparation. It keeps going if the window closes.
        var download: @MainActor (EngineID) -> Void = { _ in }
        var cancelDownload: @MainActor (EngineID) -> Void = { _ in }
        var delete: @MainActor (EngineID) -> Void = { _ in }
    }

    @Published var selectedEngine: EngineID {
        didSet { if !isSyncing, selectedEngine != oldValue { actions.selectEngine(selectedEngine) } }
    }
    @Published var statuses: [EngineID: SpeechModelStatus]
    var actions: Actions

    private var isSyncing = false

    init(selectedEngine: EngineID = .parakeetV3, statuses: [EngineID: SpeechModelStatus] = [:],
         actions: Actions = Actions()) {
        self.selectedEngine = selectedEngine
        self.statuses = statuses
        self.actions = actions
    }

    func sync(_ change: () -> Void) {
        isSyncing = true
        change()
        isSyncing = false
    }

    func status(for engine: EngineID) -> SpeechModelStatus { statuses[engine] ?? .notDownloaded }
    var selectedStatus: SpeechModelStatus { status(for: selectedEngine) }
    func info(for engine: EngineID) -> SpeechEngineInfo { SpeechEngineInfo.info(for: engine) }

    /// Convenience for wiring: feed engine progress straight in.
    func update(_ engine: EngineID, progress: ModelProgress, bytesPerSecond: Double? = nil) {
        statuses[engine] = SpeechModelStatus(progress: progress, bytesPerSecond: bytesPerSecond)
    }

    func download(_ engine: EngineID) { actions.download(engine) }
    func cancelDownload(_ engine: EngineID) { actions.cancelDownload(engine) }
    func delete(_ engine: EngineID) { actions.delete(engine) }
}

// MARK: - Claude

@MainActor
final class ClaudeViewModel: ObservableObject {
    struct Actions {
        /// Find `claude` (ClaudeLocator) and its version; updates `install`.
        var detect: @MainActor () -> Void = {}
        /// Run Anthropic's official installer script, unmodified, appending its output to `installLog`.
        var installForMe: @MainActor () -> Void = {}
        /// Write a .command file with the installer one-liner and open it in Terminal.
        var openInstallerInTerminal: @MainActor () -> Void = {}
        /// The user picked a `claude` binary by hand.
        var setClaudePath: @MainActor (URL) -> Void = { _ in }
        /// Run `claude setup-token` in a pseudo-terminal; updates `account` to `.signingIn(…)` and then
        /// `.connected(…)`. The token goes to the Keychain only.
        var connect: @MainActor () -> Void = {}
        /// Write the code from the browser to the PTY.
        var submitCode: @MainActor (String) -> Void = { _ in }
        var cancelSignIn: @MainActor () -> Void = {}
        /// A token the user made with `claude setup-token` in Terminal (already trimmed).
        var useToken: @MainActor (String) -> Void = { _ in }
        /// Delete the token from the Keychain.
        var disconnect: @MainActor () -> Void = {}
        /// One tiny Haiku request; updates `test`.
        var test: @MainActor () -> Void = {}
        /// The user chose "Use Raw mode only for now" (true) or connected after all (false).
        var setRawOnly: @MainActor (Bool) -> Void = { _ in }
    }

    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    static let homebrewCommand = "brew install --cask claude-code"
    static let setupTokenCommand = "claude setup-token"

    @Published var install: ClaudeInstallStatus {
        didSet {
            // Close the install sheet once Claude Code turns up.
            if case .found = install, isInstallSheetPresented { isInstallSheetPresented = false }
        }
    }
    /// Output of "Install for me", shown live in the sheet.
    @Published var installLog: String = ""
    @Published var isInstallSheetPresented = false
    @Published var account: ClaudeAccountStatus
    @Published var test: ClaudeTestStatus
    /// The user picked Raw-only during onboarding; the menu doesn't nag about Claude then.
    @Published var usesRawOnly: Bool
    /// Shown under the paste-a-token field.
    @Published var pasteTokenError: String? = nil

    var actions: Actions
    let dates: any DateSource

    init(install: ClaudeInstallStatus = .detecting, account: ClaudeAccountStatus = .unknown,
         test: ClaudeTestStatus = .idle, usesRawOnly: Bool = false, dates: any DateSource = SystemDateSource(),
         actions: Actions = Actions()) {
        self.install = install
        self.account = account
        self.test = test
        self.usesRawOnly = usesRawOnly
        self.dates = dates
        self.actions = actions
    }

    var now: Date { dates.now() }

    var expiry: TokenExpiry? {
        if case .connected(let createdAt) = account { return TokenExpiry(createdAt: createdAt) }
        return nil
    }

    /// Wiring: reflect what is in the Keychain. Only the creation date is kept here.
    func update(credential: ClaudeCredential?) {
        account = credential.map { .connected(tokenCreatedAt: $0.createdAt) } ?? .notConnected
    }

    func detect() { actions.detect() }
    func showInstallSheet() { isInstallSheetPresented = true }
    func installForMe() {
        installLog = ""
        actions.installForMe()
    }
    func openInstallerInTerminal() { actions.openInstallerInTerminal() }
    func setClaudePath(_ url: URL) { actions.setClaudePath(url) }

    func connect() {
        pasteTokenError = nil
        test = .idle
        if usesRawOnly {
            usesRawOnly = false
            actions.setRawOnly(false)
        }
        actions.connect()
    }

    func submitCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        actions.submitCode(trimmed)
    }

    func cancelSignIn() { actions.cancelSignIn() }

    /// Checks the pasted text looks like a token and hands it on. Returns false (with `pasteTokenError`) if not.
    @discardableResult
    func useToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            pasteTokenError = "Paste the token that claude setup-token printed."
            return false
        }
        if trimmed.contains(where: { $0.isWhitespace }) || trimmed.count < 20 {
            pasteTokenError = "That doesn't look like a token. Copy the whole line it printed, and nothing else."
            return false
        }
        pasteTokenError = nil
        test = .idle
        actions.useToken(trimmed)
        return true
    }

    func disconnect() {
        test = .idle
        actions.disconnect()
    }

    func runTest() {
        guard test != .running else { return }
        test = .running
        actions.test()
    }

    func chooseRawOnly() {
        usesRawOnly = true
        actions.setRawOnly(true)
    }
}

// MARK: - Hotkeys

/// The current hotkeys (for display) and, once wired, a factory for KeyboardShortcuts recorder views.
@MainActor
final class HotkeysViewModel: ObservableObject {
    @Published var hotkeys: [HotkeySlot: HotkeyDisplay]
    /// Wiring sets this to return `KeyboardShortcuts.Recorder(for: …)` wrapped in AnyView. When nil, the views show
    /// the current hotkey as read-only keycaps.
    var recorder: (@MainActor (HotkeySlot) -> AnyView)?

    init(hotkeys: [HotkeySlot: HotkeyDisplay]? = nil, recorder: (@MainActor (HotkeySlot) -> AnyView)? = nil) {
        if let hotkeys {
            self.hotkeys = hotkeys
        } else {
            var defaults: [HotkeySlot: HotkeyDisplay] = [:]
            for slot in HotkeySlot.allCases { defaults[slot] = slot.defaultHotkey }
            self.hotkeys = defaults
        }
        self.recorder = recorder
    }

    func hotkey(for slot: HotkeySlot) -> HotkeyDisplay? { hotkeys[slot] }
}
