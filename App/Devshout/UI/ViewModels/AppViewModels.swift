// View models for the menu bar, onboarding and the recording pill, plus `DevshoutViewModels`, the container the
// wiring step builds once and hands to the scenes.
//
// Unsure on macOS (not compiled here): forwarding child `objectWillChange` publishers through Combine
// `Publishers.MergeMany`; `Task.sleep(nanoseconds:)` for the auto-advance delay.

import Combine
import DevshoutCore
import Foundation
import SwiftUI

// MARK: - Menu bar

@MainActor
final class MenuBarViewModel: ObservableObject {
    struct Actions {
        /// Start, or stop and finish, a dictation in the default mode (same as tapping the hotkey).
        var toggleDictation: @MainActor () -> Void = {}
        var cancelDictation: @MainActor () -> Void = {}
        var setDefaultMode: @MainActor (ModeID) -> Void = { _ in }
        var openOnboarding: @MainActor () -> Void = {}
        /// Open the Settings window (wiring refreshes what it shows first, e.g. re-detects Claude Code).
        var openSettings: @MainActor () -> Void = {}
    }

    @Published var isRecording = false
    /// Transcribing or cleaning up after a recording.
    @Published var isWorking = false
    @Published var defaultMode: ModeID {
        didSet { if !isSyncing, defaultMode != oldValue { actions.setDefaultMode(defaultMode) } }
    }
    /// Every mode that can be the default: the built-ins, then the user's own. Wiring keeps it current.
    @Published var modes: [ModeDescriptor] = ModeDescriptor.builtIns

    let claude: ClaudeViewModel
    let speech: SpeechEngineViewModel
    let microphone: MicrophoneViewModel
    let accessibility: AccessibilityViewModel
    let hotkeys: HotkeysViewModel
    var actions: Actions

    private var isSyncing = false
    private var cancellables: Set<AnyCancellable> = []

    init(defaultMode: ModeID = .tidy, claude: ClaudeViewModel, speech: SpeechEngineViewModel,
         microphone: MicrophoneViewModel, accessibility: AccessibilityViewModel, hotkeys: HotkeysViewModel,
         actions: Actions = Actions()) {
        self.defaultMode = defaultMode
        self.claude = claude
        self.speech = speech
        self.microphone = microphone
        self.accessibility = accessibility
        self.hotkeys = hotkeys
        self.actions = actions

        // The menu and icon depend on the shared models; re-render when any of them changes.
        Publishers.MergeMany([claude.objectWillChange, speech.objectWillChange, microphone.objectWillChange,
                              accessibility.objectWillChange, hotkeys.objectWillChange])
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func sync(_ change: () -> Void) {
        isSyncing = true
        change()
        isSyncing = false
    }

    var needsAttention: Bool {
        MenuStatus.needsAttention(account: claude.account, claudeSkipped: claude.usesRawOnly,
                                  model: speech.selectedStatus, microphone: microphone.permission,
                                  accessibilityTrusted: accessibility.isTrusted, now: claude.now)
    }

    var iconState: MenuBarIconState {
        MenuBarIconState.resolve(isRecording: isRecording, isWorking: isWorking, needsAttention: needsAttention)
    }

    var statusLines: [MenuStatusLine] {
        MenuStatus.lines(account: claude.account, claudeSkipped: claude.usesRawOnly, model: speech.selectedStatus,
                         microphone: microphone.permission, accessibilityTrusted: accessibility.isTrusted,
                         now: claude.now)
    }

    var dictationTitle: String { isRecording ? "Stop Dictation" : "Start Dictation" }
    var dictationHotkey: HotkeyDisplay? { hotkeys.hotkey(for: .appDefault) }

    func toggleDictation() { actions.toggleDictation() }
    func cancelDictation() { actions.cancelDictation() }
    func openOnboarding() { actions.openOnboarding() }
    func openSettings() { actions.openSettings() }
}

// MARK: - Onboarding

@MainActor
final class OnboardingViewModel: ObservableObject {
    /// How long a completed step stays on screen (with its tick) before moving on by itself.
    static let autoAdvanceDelay: TimeInterval = 0.9

    @Published private(set) var step: OnboardingStep = .welcome
    /// The "Try it" text box.
    @Published var tryItText = ""
    /// Wiring: set when the Try it dictation finishes, to show raw and tidied text side by side.
    @Published var tryItResult: TryItResult? = nil

    let microphone: MicrophoneViewModel
    let accessibility: AccessibilityViewModel
    let speech: SpeechEngineViewModel
    let claude: ClaudeViewModel
    let hotkeys: HotkeysViewModel
    /// Mark onboarding as done and close the window.
    var onFinish: @MainActor () -> Void
    /// Open the voice calibration window (the optional offer on the last step).
    var onCalibrate: @MainActor () -> Void = {}

    private var completionOnArrival: [OnboardingStep: Bool] = [:]
    private var isMonitoringLevels = false
    private var advanceTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(microphone: MicrophoneViewModel, accessibility: AccessibilityViewModel, speech: SpeechEngineViewModel,
         claude: ClaudeViewModel, hotkeys: HotkeysViewModel, startAt step: OnboardingStep = .welcome,
         onFinish: @escaping @MainActor () -> Void = {}) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.speech = speech
        self.claude = claude
        self.hotkeys = hotkeys
        self.onFinish = onFinish
        self.step = step

        let children = [microphone.objectWillChange, accessibility.objectWillChange, speech.objectWillChange,
                        claude.objectWillChange, hotkeys.objectWillChange]
        Publishers.MergeMany(children)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // objectWillChange fires before the value changes, so look again on the next turn of the main queue.
        Publishers.MergeMany(children)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.childrenChanged() }
            .store(in: &cancellables)

        completionOnArrival[step] = isComplete(step)
        // Step hooks run from windowDidAppear(), when the window is actually on screen.
    }

    // MARK: Navigation

    var steps: [OnboardingStep] { OnboardingStep.allCases }
    var isFirstStep: Bool { step.previous == nil }
    var isLastStep: Bool { step.next == nil }

    func goForward() {
        guard let next = step.next else {
            finish()
            return
        }
        go(to: next)
    }

    func goBack() {
        if let previous = step.previous { go(to: previous) }
    }

    func go(to newStep: OnboardingStep) {
        guard newStep != step else { return }
        advanceTask?.cancel()
        advanceTask = nil
        let old = step
        step = newStep
        completionOnArrival[newStep] = isComplete(newStep)
        didLeave(old)
        didEnter(newStep)
    }

    func finish() {
        windowDidDisappear()
        onFinish()
    }

    func calibrate() { onCalibrate() }

    /// Reopen (Settings → General → Reopen onboarding, menu → Set Up devshout…): at the first set-up step that
    /// still needs doing, or at Welcome when nothing or everything is done.
    func restart() {
        let setUp: [OnboardingStep] = [.microphone, .accessibility, .speechModel, .claude]
        let remaining = setUp.filter { !isDone($0) }
        let partlyDone = !remaining.isEmpty && remaining.count < setUp.count
        go(to: partlyDone ? remaining[0] : .welcome)
    }

    /// Whether a step's job is already done, for the ticks in the step indicator. Set-up steps go by the real
    /// state (so they are ticked when onboarding is reopened); the others once the user has moved past them.
    func isDone(_ step: OnboardingStep) -> Bool {
        switch step {
        case .microphone: microphone.permission == .granted
        case .accessibility: accessibility.isTrusted
        case .speechModel: speech.selectedStatus.isReady
        case .claude: claude.account.isConnected
        case .welcome, .hotkeys, .tryIt: step < self.step
        }
    }

    /// Called by `OnboardingView` when its window appears: runs the current step's hooks again.
    func windowDidAppear() {
        completionOnArrival[step] = isComplete(step)
        didEnter(step)
    }

    /// Called by `OnboardingView` when its window closes (red button or Done): stops the level meter and any pending
    /// auto-advance, without marking onboarding as finished.
    func windowDidDisappear() {
        advanceTask?.cancel()
        advanceTask = nil
        didLeave(step)
    }

    // MARK: Step state

    func isComplete(_ step: OnboardingStep) -> Bool {
        switch step {
        case .welcome, .hotkeys, .tryIt:
            return false
        case .microphone:
            return microphone.permission == .granted
        case .accessibility:
            return accessibility.isTrusted
        case .speechModel:
            return speech.selectedStatus.isReady
        case .claude:
            guard claude.account.isConnected else { return false }
            if case .succeeded = claude.test { return true }
            return false
        }
    }

    /// Whether the primary button may move on. Steps that wait on the user stay passable: everything can be done
    /// later from Settings.
    var canContinue: Bool {
        switch step {
        case .speechModel: speech.selectedStatus.isBusy || speech.selectedStatus.isReady
        case .claude: claude.account.isConnected || claude.usesRawOnly
        default: true
        }
    }

    var primaryButtonTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .speechModel where speech.selectedStatus.isBusy: "Continue While It Downloads"
        case .tryIt: "Done"
        default: "Continue"
        }
    }

    /// The secondary "do it later" link per step, if any.
    var skipTitle: String? {
        switch step {
        case .microphone, .accessibility: "Not Now"
        case .speechModel: canContinue ? nil : "Choose Later"
        case .claude: claude.account.isConnected ? nil : "Use Raw Mode Only for Now"
        default: nil
        }
    }

    func skip() {
        if step == .claude { claude.chooseRawOnly() }
        goForward()
    }

    // MARK: Hooks

    private func didEnter(_ step: OnboardingStep) {
        switch step {
        case .microphone, .tryIt:
            startLevelMonitoringIfAllowed()
        case .claude:
            switch claude.install {
            case .notFound, .installFailed: claude.detect()
            default: break
            }
        default:
            break
        }
    }

    private func didLeave(_ step: OnboardingStep) {
        switch step {
        case .microphone, .tryIt:
            if isMonitoringLevels {
                isMonitoringLevels = false
                microphone.stopLevelMonitoring(for: .onboarding)
            }
        default:
            break
        }
    }

    private func startLevelMonitoringIfAllowed() {
        // MicrophoneViewModel waits for permission itself; this only keeps start/stop balanced.
        guard !isMonitoringLevels else { return }
        isMonitoringLevels = true
        microphone.startLevelMonitoring(for: .onboarding)
    }

    private func childrenChanged() {
        // Once connected during onboarding, run the one-line test straight away.
        if step == .claude, claude.account.isConnected, claude.test == .idle {
            claude.runTest()
        }
        // Move on by itself when the step's condition turned true while the user was on it.
        let done = isComplete(step)
        if done, completionOnArrival[step] == false, advanceTask == nil {
            let from = step
            advanceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.autoAdvanceDelay * 1_000_000_000))
                guard let self, !Task.isCancelled, self.step == from else { return }
                self.advanceTask = nil
                self.goForward()
            }
        }
    }
}

// MARK: - Recording pill

@MainActor
final class RecordingPillViewModel: ObservableObject {
    struct Actions {
        /// Stop and finish (same as the hotkey).
        var stop: @MainActor () -> Void = {}
        /// Cancel (same as Esc). The audio is kept in history.
        var cancel: @MainActor () -> Void = {}
        /// Skip Claude and paste the raw text now.
        var pasteRawNow: @MainActor () -> Void = {}
    }

    @Published var phase: PillPhase = .recording
    @Published var mode: ModeID = .tidy
    /// The modes that exist, for the chip's name, symbol and colour. Wiring keeps it current.
    @Published var modes: [ModeDescriptor] = ModeDescriptor.builtIns
    /// When the recording started; the timer counts from here.
    @Published var startedAt: Date = Date()
    /// Frozen duration once recording stops (nil while recording).
    @Published var finalDuration: TimeInterval? = nil
    /// The latest chunk's transcript, for the optional second line.
    @Published var liveText: String? = nil
    /// A short note for the second line that wins over everything else (e.g. "Still finishing the last
    /// dictation", or the details of an error). Wiring sets and clears it.
    @Published var notice: String? = nil
    @Published var showsLiveText = true
    /// Set by `OverlayPanel` from its own tracking area (SwiftUI hover may not fire in a non-key panel).
    @Published var isHovering = false

    let levels: AudioLevelViewModel
    var actions: Actions

    init(levels: AudioLevelViewModel? = nil, actions: Actions = Actions()) {
        self.levels = levels ?? AudioLevelViewModel()
        self.actions = actions
    }

    /// Wiring: a new recording started.
    func begin(mode: ModeID, at date: Date = Date()) {
        self.mode = mode
        startedAt = date
        finalDuration = nil
        liveText = nil
        notice = nil
        phase = .recording
        levels.reset()
    }

    /// Wiring: recording stopped; freeze the timer.
    func recordingStopped(duration: TimeInterval) {
        finalDuration = duration
    }

    /// What the chip shows for the mode in use.
    var modeDescriptor: ModeDescriptor { modes.descriptor(for: mode) }

    var title: String { phase.title(mode: modeDescriptor) }

    var secondLine: String? {
        if let notice, !notice.isEmpty { return notice }
        if let subtitle = phase.subtitle { return subtitle }
        guard showsLiveText, phase.allowsLiveText, let liveText, !liveText.isEmpty else { return nil }
        return liveText
    }

    var showsHoverControls: Bool { isHovering && phase.isRecording }

    var showsPasteRawButton: Bool { if case .cleaning = phase { true } else { false } }

    func stop() { actions.stop() }
    func cancel() { actions.cancel() }
    func pasteRawNow() { actions.pasteRawNow() }
}

// MARK: - Container

/// Every view model, built once by the wiring step. Shared models are the same instances everywhere, so
/// onboarding, Settings and the menu agree.
@MainActor
final class DevshoutViewModels {
    let microphone: MicrophoneViewModel
    let accessibility: AccessibilityViewModel
    let speech: SpeechEngineViewModel
    let claude: ClaudeViewModel
    let hotkeys: HotkeysViewModel
    let general: GeneralSettingsViewModel
    let modes: ModesSettingsViewModel
    let apps: AppsSettingsViewModel
    let glossary: GlossaryViewModel
    let privacy: PrivacyViewModel
    let history: HistoryViewModel
    let calibration: CalibrationViewModel
    let menuBar: MenuBarViewModel
    let onboarding: OnboardingViewModel
    let pill: RecordingPillViewModel

    /// Any model left out is created with its defaults (no-op actions).
    init(microphone: MicrophoneViewModel? = nil,
         accessibility: AccessibilityViewModel? = nil,
         speech: SpeechEngineViewModel? = nil,
         claude: ClaudeViewModel? = nil,
         hotkeys: HotkeysViewModel? = nil,
         general: GeneralSettingsViewModel? = nil,
         modes: ModesSettingsViewModel? = nil,
         apps: AppsSettingsViewModel? = nil,
         glossary: GlossaryViewModel? = nil,
         privacy: PrivacyViewModel? = nil,
         pill: RecordingPillViewModel? = nil) {
        let microphone = microphone ?? MicrophoneViewModel()
        let accessibility = accessibility ?? AccessibilityViewModel()
        let speech = speech ?? SpeechEngineViewModel()
        let claude = claude ?? ClaudeViewModel()
        let hotkeys = hotkeys ?? HotkeysViewModel()
        self.microphone = microphone
        self.accessibility = accessibility
        self.speech = speech
        self.claude = claude
        self.hotkeys = hotkeys
        self.general = general ?? GeneralSettingsViewModel()
        self.modes = modes ?? ModesSettingsViewModel()
        self.apps = apps ?? AppsSettingsViewModel()
        self.glossary = glossary ?? GlossaryViewModel()
        self.privacy = privacy ?? PrivacyViewModel()
        self.history = HistoryViewModel()
        self.calibration = CalibrationViewModel(speech: speech, microphone: microphone)
        self.menuBar = MenuBarViewModel(claude: claude, speech: speech, microphone: microphone,
                                        accessibility: accessibility, hotkeys: hotkeys)
        self.onboarding = OnboardingViewModel(microphone: microphone, accessibility: accessibility, speech: speech,
                                              claude: claude, hotkeys: hotkeys)
        // The pill's waveform uses the same level feed as the meters.
        self.pill = pill ?? RecordingPillViewModel(levels: microphone.level)
    }
}
