// AppCoordinator owns everything: the files under ~/Library/Application Support/devshout, settings.json, history,
// the glossary, the engines, Claude, permissions, hotkeys and the dictation pipeline, and the view models the
// scenes show. It is built once (`shared`) and started by the app delegate.
//
// Rule of thumb here: nothing slow runs on the main actor. Engines, the VAD, the dictation session and Claude are
// actors or run child processes; history and file-size work goes through detached tasks.

import AppKit
import Combine
import DevshoutCore
import DevshoutMac
import Foundation
import KeyboardShortcuts
import SwiftUI

@MainActor
final class AppCoordinator {
    static let shared = AppCoordinator()

    let paths: AppPaths
    let models: DevshoutViewModels

    private let settingsStore: SettingsStore
    private(set) var settings: AppSettings
    /// The same settings, for closures that run off the main actor (paste method, sounds).
    private let settingsBox: LockedBox<AppSettings>
    private let defaults = UserDefaults.standard

    let history: HistoryStore
    /// What Settings → History does with a recording (play its audio, re-run it through Claude).
    let historyActions: HistoryController
    let glossary: GlossaryController
    let engines: EngineController
    let claude: ClaudeController
    let permissions: PermissionsController
    let devices: InputDevicesController
    let levelMeter: LevelMeterController
    let dictation: DictationController
    let calibration: CalibrationController
    let recorder: MicRecorder
    let vad: SileroVAD
    let sounds: Sounds
    /// Started early so `lastExternal` is known from launch.
    private let frontmost: FrontmostApp
    private let onboardingWindow: OnboardingWindowController
    private let settingsWindow: SettingsWindowController

    private var started = false
    /// The General preferences as last applied (to tell which one the user just changed).
    private var lastGeneral = GeneralPreferences()
    /// The dictation hotkeys as they were when no two of them were the same (see `hotkeyRecorded`).
    private var shortcuts: [HotkeySlot: KeyboardShortcuts.Shortcut] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let paths = AppPaths()
        self.paths = paths
        settingsStore = SettingsStore(url: paths.settings)
        let loaded = settingsStore.load()
        settings = loaded
        let box = LockedBox(loaded)
        settingsBox = box

        // View models first: the controllers below fill in their state and actions.
        let microphone = MicrophoneViewModel(selectedDeviceID: loaded.inputDeviceUID)
        let speech = SpeechEngineViewModel(selectedEngine: loaded.engine)
        let claudeModel = ClaudeViewModel()
        let glossaryModel = GlossaryViewModel()
        let models = DevshoutViewModels(microphone: microphone, speech: speech, claude: claudeModel,
                                        glossary: glossaryModel)
        self.models = models

        // Locals first, then the stored properties: nothing reads `self` before it is fully initialised.
        let history = HistoryStore(root: paths.recordings)
        let glossary = GlossaryController(url: paths.glossary, model: glossaryModel)
        let engines = EngineController(selected: loaded.engine, locations: paths.models, model: speech)
        let claude = ClaudeController(paths: paths, pathOverride: loaded.claudePathOverride, model: claudeModel)
        let levelMeter = LevelMeterController(level: microphone.level, scratch: paths.meterScratch)

        // The dictation recorder feeds the same level model as the meters, which the pill's waveform draws.
        let level = microphone.level
        let recorder = MicRecorder(deviceUID: loaded.inputDeviceUID, levelHandler: { measured in
            let value = measured.meterValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { level.push(value) }
            }
        })
        let vad = SileroVAD(baseDirectory: paths.root)
        let sounds = Sounds(isEnabled: { box.value.soundsEnabled })
        let paster = Paster(method: { box.value.pasteMethod == .accessibility ? .accessibility : .commandV })

        let dictation = DictationController(
            services: DictationController.Services(
                settings: { box.value },
                engines: engines,
                claude: claude,
                glossary: glossary.state,
                history: history,
                deliverer: paster,
                recorder: recorder,
                vad: vad,
                sounds: sounds,
                levelMeter: levelMeter
            ),
            pill: models.pill,
            menuBar: models.menuBar
        )

        self.history = history
        self.historyActions = HistoryController(model: models.history, history: history, claude: claude,
                                                glossary: glossary.state, settings: { box.value })
        self.glossary = glossary
        self.engines = engines
        self.claude = claude
        self.permissions = PermissionsController(microphone: microphone, accessibility: models.accessibility)
        self.devices = InputDevicesController(microphone: microphone, selectedUID: loaded.inputDeviceUID)
        self.levelMeter = levelMeter
        self.recorder = recorder
        self.vad = vad
        self.sounds = sounds
        self.dictation = dictation
        self.calibration = CalibrationController(
            services: CalibrationController.Services(
                paths: paths,
                settings: { box.value },
                engines: engines,
                glossary: glossary,
                glossaryEditor: glossaryModel,
                claude: claude,
                vad: vad,
                levelMeter: levelMeter,
                isDictationActive: { dictation.isActive }
            ),
            model: models.calibration
        )
        self.frontmost = FrontmostApp.shared
        self.onboardingWindow = OnboardingWindowController(model: models.onboarding)
        self.settingsWindow = SettingsWindowController(models: models)

        wire()
    }

    // MARK: Launch

    /// Called once from `applicationDidFinishLaunching`.
    func start() {
        guard !started else { return }
        started = true
        paths.createFolders()

        // History housekeeping off the main actor: recover recordings cut short by a quit or crash, and drop
        // audio past its retention.
        let history = history
        let retention = settings.audioRetentionDays
        Task.detached(priority: .utility) {
            history.recoverOrphans()
            history.applyRetention(now: Date(), audioDays: retention)
        }

        glossary.load()
        glossary.state.setTokenCounter(engines.tokenCounter)
        permissions.start()
        claude.detect()
        engines.prepareSelectedIfDownloaded()
        // The VAD model is small; fetch and load it in the background (dictation copes without it).
        let vad = vad
        Task.detached(priority: .utility) { try? await vad.prepare() }
        dictation.startHotkeys()
        refreshHotkeyDisplay()
        refreshStorage()
        calibration.loadLastResult()

        if !defaults.bool(forKey: AppDefaultsKey.onboardingCompleted) {
            showOnboarding()
        }
        // For checking a screen after a build: `open devshout.app --args -openSettingsTab history`.
        if let name = defaults.string(forKey: AppDefaultsKey.openSettingsTab), let tab = SettingsTab(rawValue: name) {
            openSettings(tab: tab)
        }
        if defaults.bool(forKey: AppDefaultsKey.openCalibration) { calibration.open() }
    }

    // MARK: Windows

    func showOnboarding() {
        // Already open (perhaps behind another window): bring it back where it was, not back to Welcome.
        if !onboardingWindow.isVisible { models.onboarding.restart() }
        onboardingWindow.show()
    }

    /// devshout.app was opened again while running (Finder, Spotlight, the Dock icon): back to onboarding while
    /// it is open, otherwise Settings.
    func handleReopen() {
        if onboardingWindow.isVisible {
            onboardingWindow.show()
        } else {
            openSettings()
        }
    }

    func openSettings(tab: SettingsTab? = nil) {
        // Refresh what Settings shows, then open the window.
        if case .notFound = models.claude.install { claude.detect() }
        if case .installFailed = models.claude.install { claude.detect() }
        devices.refresh(selectedUID: settings.inputDeviceUID)
        refreshStorage()
        // Launch at login can be changed in System Settings → Login Items: show what is true now.
        let launch = LaunchAtLogin.isEnabled
        if models.general.preferences.launchAtLogin != launch {
            models.general.sync { models.general.preferences.launchAtLogin = launch }
        }
        lastGeneral.launchAtLogin = launch
        settingsWindow.show(tab: tab)
    }

    // MARK: Settings

    private func updateSettings(_ change: (inout AppSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        settingsBox.value = next
        do {
            try settingsStore.save(next)
        } catch {
            NSLog("devshout: couldn't save settings.json: \(ErrorText.describe(error))")
        }
    }

    // MARK: Wiring

    private func wire() {
        let models = models

        // Engines and the glossary's Whisper token counter.
        engines.onSelect = { [weak self] id in
            guard let self else { return }
            self.updateSettings { $0.engine = id }
            self.glossary.state.setTokenCounter(self.engines.tokenCounter)
        }
        engines.isDictationActive = { [weak self] in
            guard let self else { return false }
            return self.dictation.isActive || self.calibration.isUsingEngines
        }
        wireCalibration()

        claude.onPathOverride = { [weak self] path in self?.updateSettings { $0.claudePathOverride = path } }

        // Microphone: device choice and the level meter.
        devices.onSelect = { [weak self] uid in
            guard let self else { return }
            self.updateSettings { $0.inputDeviceUID = uid }
            self.recorder.deviceUID = uid
            self.levelMeter.setDevice(uid)
        }
        levelMeter.setDevice(settings.inputDeviceUID)
        models.microphone.actions.startLevelMonitoring = { [weak self] in self?.levelMeter.setWanted(true) }
        models.microphone.actions.stopLevelMonitoring = { [weak self] in self?.levelMeter.setWanted(false) }

        wireGeneral()
        wireModes()
        wireApps()
        wirePrivacy()
        wireHistory()
        wireHotkeys()
        publishModes()

        // Menu bar.
        models.menuBar.sync { models.menuBar.defaultMode = settings.defaultMode }
        models.menuBar.actions = MenuBarViewModel.Actions(
            toggleDictation: { [weak self] in self?.dictation.toggleFromMenu() },
            cancelDictation: { [weak self] in self?.dictation.cancelFromMenu() },
            setDefaultMode: { [weak self] mode in self?.updateSettings { $0.defaultMode = mode } },
            openOnboarding: { [weak self] in self?.showOnboarding() },
            openSettings: { [weak self] in self?.openSettings() }
        )

        // Onboarding.
        models.onboarding.onFinish = { [weak self] in
            guard let self else { return }
            self.defaults.set(true, forKey: AppDefaultsKey.onboardingCompleted)
            self.onboardingWindow.close()
        }
        dictation.tryIt = DictationController.TryIt(
            isActive: { [weak self] in
                guard let self else { return false }
                return self.onboardingWindow.isFrontmost && self.models.onboarding.step == .tryIt
            },
            deliver: { [weak self] raw, cleaned, delivered in
                guard let self else { return }
                let onboarding = self.models.onboarding
                let existing = onboarding.tryItText.trimmingCharacters(in: .whitespacesAndNewlines)
                onboarding.tryItText = existing.isEmpty ? delivered : existing + " " + delivered
                onboarding.tryItResult = TryItResult(raw: raw, cleaned: cleaned)
            }
        )
        dictation.onFinished = { [weak self] in self?.refreshStorage() }
    }

    /// Voice calibration: dictation stands aside while it records or measures, and onboarding can open it.
    private func wireCalibration() {
        dictation.startBlocker = { [weak self] in self?.calibration.dictationBlocker }
        models.onboarding.onCalibrate = { [weak self] in self?.calibration.open() }
    }

    private func wireGeneral() {
        let general = models.general
        lastGeneral = Self.preferences(from: settings)
        general.sync { general.preferences = lastGeneral }
        general.onChange = { [weak self] preferences in self?.applyGeneral(preferences) }
        general.reopenOnboarding = { [weak self] in self?.showOnboarding() }
    }

    private func applyGeneral(_ preferences: GeneralPreferences) {
        // Only touch the login item when that toggle itself changed: it may have been changed in System Settings
        // since, and an unrelated change here mustn't undo that.
        let launchToggled = preferences.launchAtLogin != lastGeneral.launchAtLogin
        lastGeneral = preferences
        if launchToggled, preferences.launchAtLogin != LaunchAtLogin.isEnabled {
            do {
                try LaunchAtLogin.setEnabled(preferences.launchAtLogin)
                if LaunchAtLogin.status == .requiresApproval { LaunchAtLogin.openSystemSettings() }
            } catch {
                NSLog("devshout: launch at login: \(ErrorText.describe(error))")
            }
            // Show what macOS actually did.
            let actual = LaunchAtLogin.isEnabled
            if actual != preferences.launchAtLogin {
                let general = models.general
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        general.sync { general.preferences.launchAtLogin = actual }
                        AppCoordinator.shared.lastGeneral.launchAtLogin = actual
                    }
                }
            }
        }
        let behaviour: HotkeyBehaviour
        switch preferences.hotkeyBehaviour {
        case .tapOrHold: behaviour = .tapToggleHoldToTalk
        case .toggleOnly: behaviour = .toggleOnly
        case .holdOnly: behaviour = .holdOnly
        }
        updateSettings {
            $0.hotkeyBehaviour = behaviour
            $0.soundsEnabled = preferences.playsSounds
            $0.pasteMethod = preferences.pasteMethod == .accessibility ? .accessibility : .commandV
            $0.showLivePreview = preferences.showsLivePreview
        }
        dictation.setBehaviour(behaviour)
    }

    private static func preferences(from settings: AppSettings) -> GeneralPreferences {
        var preferences = GeneralPreferences()
        preferences.launchAtLogin = LaunchAtLogin.isEnabled
        switch settings.hotkeyBehaviour {
        case .tapToggleHoldToTalk: preferences.hotkeyBehaviour = .tapOrHold
        case .toggleOnly: preferences.hotkeyBehaviour = .toggleOnly
        case .holdOnly: preferences.hotkeyBehaviour = .holdOnly
        }
        preferences.playsSounds = settings.soundsEnabled
        preferences.pasteMethod = settings.pasteMethod == .accessibility ? .accessibility : .commandV
        preferences.showsLivePreview = settings.showLivePreview
        return preferences
    }

    private func wireModes() {
        let modes = models.modes
        modes.configs = settings.modes
        modes.customModes = settings.customModes
        var instructions: [ModeID: String] = [:]
        for mode in ModeID.builtIns {
            if let text = PromptBuilder.defaultInstructions(for: mode) { instructions[mode] = text }
        }
        modes.defaultInstructions = instructions
        modes.actions = ModesSettingsViewModel.Actions(
            saveBuiltIn: { [weak self] config in self?.updateSettings { $0.modes[config.id] = config } },
            saveCustomModes: { [weak self] list in
                guard let self else { return }
                self.updateSettings {
                    $0.customModes = list
                    // A deleted mode can't stay the default mode or an app's mode.
                    $0.dropReferencesToMissingModes()
                }
                self.publishModes()
            }
        )
    }

    /// Tells everything that lists or shows modes what the modes are now: the menu's default-mode picker, the
    /// Apps tab, History, the recording pill and the hotkey centre. Called at launch and whenever the user's modes
    /// change (a rename shows at once; a deleted mode's hotkey is unregistered and forgotten).
    private func publishModes() {
        let descriptors = settings.modeDescriptors
        if models.menuBar.modes != descriptors { models.menuBar.modes = descriptors }
        if models.apps.modes != descriptors { models.apps.modes = descriptors }
        if models.history.modes != descriptors { models.history.modes = descriptors }
        if models.pill.modes != descriptors { models.pill.modes = descriptors }
        if models.modes.customModes != settings.customModes { models.modes.customModes = settings.customModes }

        // Deleting a mode may have changed the default mode and removed per-app rules.
        if models.menuBar.defaultMode != settings.defaultMode {
            models.menuBar.sync { models.menuBar.defaultMode = settings.defaultMode }
        }
        let table = settings.perAppModes
        let rules = models.apps.rules.filter { table[$0.bundleID] != nil }
        if rules != models.apps.rules {
            models.apps.sync {
                models.apps.rules = rules
                models.apps.selection = models.apps.selection.filter { table[$0] != nil }
            }
        }

        dictation.hotkeys.setCustomModes(settings.customModes.map(\.id))
        refreshHotkeyDisplay()
    }

    private func wireApps() {
        let apps = models.apps
        let rules = settings.perAppModes.map { bundleID, mode in
            AppModeRule(bundleID: bundleID, name: Self.appName(for: bundleID), mode: mode)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        apps.sync { apps.rules = rules }
        apps.runningApps = {
            let me = ProcessInfo.processInfo.processIdentifier
            return NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.activationPolicy == .regular, app.processIdentifier != me,
                      let bundleID = app.bundleIdentifier else { return nil }
                return AppCandidate(bundleID: bundleID, name: app.localizedName ?? bundleID, url: app.bundleURL)
            }
        }
        apps.onChange = { [weak self] rules in
            let table = Dictionary(rules.map { ($0.bundleID, $0.mode) }, uniquingKeysWith: { _, last in last })
            self?.updateSettings { $0.perAppModes = table }
        }
    }

    private static func appName(for bundleID: String) -> String {
        if let name = FrontmostApp.name(forBundleID: bundleID) { return name }
        if let suggestion = AppModeRule.suggestions.first(where: { $0.bundleID == bundleID }) { return suggestion.name }
        return bundleID
    }

    private func wirePrivacy() {
        let privacy = models.privacy
        privacy.sync { privacy.audioRetention = Self.retention(from: settings.audioRetentionDays) }
        privacy.actions = PrivacyViewModel.Actions(
            setAudioRetention: { [weak self] retention in
                guard let self else { return }
                self.updateSettings { $0.audioRetentionDays = retention.days }
                let history = self.history
                Task.detached(priority: .utility) {
                    history.applyRetention(now: Date(), audioDays: retention.days)
                }
                self.refreshStorage()
            },
            showInFinder: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.open(self.paths.root)
            },
            deleteAllHistory: { [weak self] in
                guard let self else { return }
                let history = self.history
                Task {
                    let failure: String? = await Task.detached {
                        do {
                            try history.deleteAll()
                            return nil
                        } catch {
                            return ErrorText.describe(error)
                        }
                    }.value
                    if let failure { NSLog("devshout: delete all history: \(failure)") }
                    self.refreshStorage()
                }
            }
        )
    }

    private func wireHistory() {
        let actions = historyActions
        actions.isRecording = { [weak self] in self?.dictation.isRecording ?? false }
        actions.onChange = { [weak self] in self?.refreshStorage() }
        // Never play over a recording: the microphone would pick the old dictation up.
        dictation.onWillStart = { [weak actions] in actions?.stopPlayback() }
        models.history.actions = HistoryViewModel.Actions(
            reload: { [weak self] in self?.refreshStorage() },
            delete: { [weak self] id in
                guard let self else { return }
                self.historyActions.forget(id)
                do {
                    try self.history.delete(id)
                } catch {
                    NSLog("devshout: delete recording: \(ErrorText.describe(error))")
                }
                self.refreshStorage()
            },
            showInFinder: { [weak self] id in
                guard let self, let folder = self.history.folder(for: id) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            },
            play: { [weak actions] id in actions?.play(id) },
            stopPlayback: { [weak actions] in actions?.stopPlayback() },
            rerun: { [weak actions] id, mode in actions?.rerun(id, mode: mode) },
            cancelRerun: { [weak actions] id in actions?.cancelRerun(id) },
            addCorrection: { [glossary] heard, term, kind in
                try glossary.addCorrection(heard: heard, term: term, kind: kind)
            },
            existingGlossaryTerm: { [glossary] term in glossary.existingTerm(matching: term) }
        )
    }

    private static func retention(from days: Int?) -> AudioRetention {
        guard let days, days > 0 else { return .forever }
        if days <= 7 { return .days7 }
        if days <= 30 { return .days30 }
        return .days90
    }

    /// The recordings for Settings → History, and their count and bytes on disk for Settings → Privacy.
    func refreshStorage() {
        let history = history
        let root = paths.recordings
        let privacy = models.privacy
        let historyModel = models.history
        Task {
            let stats: (recordings: [Recording], bytes: Int64) = await Task.detached(priority: .utility) {
                (history.list(), ModelLocations.directorySize(root))
            }.value
            if historyModel.recordings != stats.recordings { historyModel.recordings = stats.recordings }
            if privacy.recordingCount != stats.recordings.count { privacy.recordingCount = stats.recordings.count }
            if privacy.storageUsed != stats.bytes { privacy.storageUsed = stats.bytes }
        }
    }

    // MARK: Hotkeys

    private func wireHotkeys() {
        models.hotkeys.recorder = { [weak self] slot in
            AnyView(
                KeyboardShortcuts.Recorder(for: slot.dictationHotkey.name, onChange: { shortcut in
                    // After the recorder has finished storing it.
                    DispatchQueue.main.async { self?.hotkeyRecorded(shortcut, for: slot) }
                })
                .fixedSize()
            )
        }
        // Also catch changes made elsewhere (KeyboardShortcuts posts this after storing a shortcut).
        NotificationCenter.default.publisher(for: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshHotkeyDisplay() }
            .store(in: &cancellables)
    }

    /// Every dictation hotkey there is: the fixed four and one per custom mode.
    private var hotkeySlots: [HotkeySlot] {
        HotkeySlot.builtIns + settings.customModes.map { .custom($0.id) }
    }

    /// A recorder stored a shortcut (or cleared it). Two dictation hotkeys with the same keys would both fire on
    /// one press (start in one mode and switch to the other at once), which the recorder doesn't check for now
    /// that there can be any number of them: the slot that just took another's keys gets back what it had.
    private func hotkeyRecorded(_ shortcut: KeyboardShortcuts.Shortcut?, for slot: HotkeySlot) {
        if let shortcut,
           hotkeySlots.contains(where: { $0 != slot && KeyboardShortcuts.getShortcut(for: $0.dictationHotkey.name) == shortcut }) {
            KeyboardShortcuts.setShortcut(shortcuts[slot], for: slot.dictationHotkey.name)
            NSSound.beep()
        }
        refreshHotkeyDisplay()
    }

    func refreshHotkeyDisplay() {
        var displays: [HotkeySlot: HotkeyDisplay] = [:]
        var current: [HotkeySlot: KeyboardShortcuts.Shortcut] = [:]
        for slot in hotkeySlots {
            if let shortcut = KeyboardShortcuts.getShortcut(for: slot.dictationHotkey.name) {
                displays[slot] = HotkeyDisplay(shortcut)
                current[slot] = shortcut
            }
        }
        // Kept only while no two are the same, so that a clash can be put back to how things were.
        if Set(current.values).count == current.count { shortcuts = current }
        if models.hotkeys.hotkeys != displays { models.hotkeys.hotkeys = displays }
    }
}

// MARK: - Hotkey mapping

extension HotkeySlot {
    /// The DevshoutMac hotkey behind this UI slot.
    var dictationHotkey: DictationHotkey {
        switch self {
        case .appDefault: .dictate
        case .tidy: .dictateTidy
        case .structure: .dictateStructure
        case .raw: .dictateRaw
        case .custom(let mode): .custom(mode)
        }
    }
}

extension HotkeyDisplay {
    /// "⌥Space" from a KeyboardShortcuts shortcut.
    @MainActor
    init(_ shortcut: KeyboardShortcuts.Shortcut) {
        var modifiers: Modifiers = []
        let flags = shortcut.modifiers
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        // `description` is the modifier symbols followed by the key ("⌥Space"); keep the key part.
        let symbols: Set<Character> = ["⌃", "⌥", "⇧", "⌘", "🌐"]
        let key = String(shortcut.description.drop(while: { symbols.contains($0) }))
        self.init(modifiers: modifiers, key: key.isEmpty ? "?" : key)
    }
}
