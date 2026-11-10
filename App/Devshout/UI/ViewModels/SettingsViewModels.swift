// View models for the Settings tabs that aren't shared with onboarding: General, Modes, Apps, Glossary and
// Privacy & Storage. (Transcription uses SpeechEngineViewModel + MicrophoneViewModel; Claude uses ClaudeViewModel.)
//
// Values the user edits call their `onChange`/action closure from didSet. Use `sync { … }` to set them from
// outside without the echo.
//
// Unsure on macOS (not compiled here): `Combine.debounce` on RunLoop.main for the glossary recount.

import Combine
import DevshoutCore
import Foundation
import SwiftUI

// MARK: - General

@MainActor
final class GeneralSettingsViewModel: ObservableObject {
    @Published var preferences: GeneralPreferences {
        didSet { if !isSyncing, preferences != oldValue { onChange(preferences) } }
    }
    /// Persist, and apply what needs applying (e.g. `SMAppService.mainApp.register()` for launch at login).
    var onChange: @MainActor (GeneralPreferences) -> Void
    var reopenOnboarding: @MainActor () -> Void

    private var isSyncing = false

    init(preferences: GeneralPreferences = GeneralPreferences(),
         onChange: @escaping @MainActor (GeneralPreferences) -> Void = { _ in },
         reopenOnboarding: @escaping @MainActor () -> Void = {}) {
        self.preferences = preferences
        self.onChange = onChange
        self.reopenOnboarding = reopenOnboarding
    }

    func sync(_ change: () -> Void) {
        isSyncing = true
        change()
        isSyncing = false
    }
}

// MARK: - Modes

@MainActor
final class ModesSettingsViewModel: ObservableObject {
    static let timeoutRange: ClosedRange<Double> = 5...120
    static let timeoutStep: Double = 5

    @Published var configs: [ModeID: ModeConfig]
    @Published var selectedMode: ModeID = .tidy
    /// The built-in instructions per mode (from Core's prompt builder), shown when there is no custom text.
    var defaultInstructions: [ModeID: String]
    /// Persist one mode's config.
    var onChange: @MainActor (ModeConfig) -> Void

    init(configs: [ModeID: ModeConfig] = ModeConfig.defaults, defaultInstructions: [ModeID: String] = [:],
         onChange: @escaping @MainActor (ModeConfig) -> Void = { _ in }) {
        self.configs = configs
        self.defaultInstructions = defaultInstructions
        self.onChange = onChange
    }

    func config(for mode: ModeID) -> ModeConfig {
        configs[mode] ?? ModeConfig.defaults[mode] ?? ModeConfig(id: mode, claudeModel: "haiku", timeout: 20)
    }

    func update(_ mode: ModeID, _ change: (inout ModeConfig) -> Void) {
        var config = config(for: mode)
        let before = config
        change(&config)
        guard config != before else { return }
        configs[mode] = config
        onChange(config)
    }

    // Bindings for the views.

    func modelBinding(for mode: ModeID) -> Binding<String> {
        // Aliases are matched in lower case so "Haiku" still selects the Haiku row.
        Binding(get: {
                    let model = self.config(for: mode).claudeModel
                    return ClaudeModelOption(alias: model)?.rawValue ?? model
                },
                set: { value in self.update(mode) { $0.claudeModel = value } })
    }

    func timeoutBinding(for mode: ModeID) -> Binding<Double> {
        Binding(get: { self.config(for: mode).timeout },
                set: { value in
                    let clamped = min(max(value, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
                    self.update(mode) { $0.timeout = clamped }
                })
    }

    /// The text in the instructions editor: the custom text, or the default when there is none. Typing text equal
    /// to the default clears the custom value.
    func instructionsBinding(for mode: ModeID) -> Binding<String> {
        Binding(get: { self.instructions(for: mode) },
                set: { value in
                    // Blank text means "use the built-in instructions", never "no instructions".
                    let isBlank = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let isDefault = isBlank || value == (self.defaultInstructions[mode] ?? "")
                    self.update(mode) { $0.customInstructions = isDefault ? nil : value }
                })
    }

    func instructions(for mode: ModeID) -> String {
        config(for: mode).customInstructions ?? defaultInstructions[mode] ?? ""
    }

    func hasCustomInstructions(for mode: ModeID) -> Bool { config(for: mode).customInstructions != nil }

    func resetInstructions(for mode: ModeID) {
        update(mode) { $0.customInstructions = nil }
    }
}

// MARK: - Apps

@MainActor
final class AppsSettingsViewModel: ObservableObject {
    @Published var rules: [AppModeRule] {
        didSet { if !isSyncing, rules != oldValue { onChange(rules) } }
    }
    @Published var selection: Set<AppModeRule.ID> = []
    /// Apps running now (wiring: `NSWorkspace.shared.runningApplications` with `.regular` activation policy).
    var runningApps: @MainActor () -> [AppCandidate]
    var onChange: @MainActor ([AppModeRule]) -> Void

    private var isSyncing = false

    init(rules: [AppModeRule] = [], runningApps: @escaping @MainActor () -> [AppCandidate] = { [] },
         onChange: @escaping @MainActor ([AppModeRule]) -> Void = { _ in }) {
        self.rules = rules
        self.runningApps = runningApps
        self.onChange = onChange
    }

    func sync(_ change: () -> Void) {
        isSyncing = true
        change()
        isSyncing = false
    }

    /// Running apps that don't have a rule yet, by name.
    func addableRunningApps() -> [AppCandidate] {
        let existing = Set(rules.map(\.bundleID))
        var seen = Set<String>()
        return runningApps()
            .filter { !existing.contains($0.bundleID) && seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var missingSuggestions: [AppModeRule] {
        let existing = Set(rules.map(\.bundleID))
        return AppModeRule.suggestions.filter { !existing.contains($0.bundleID) }
    }

    func add(_ app: AppCandidate, mode: ModeID = .tidy) {
        guard !rules.contains(where: { $0.bundleID == app.bundleID }) else {
            selection = [app.bundleID]
            return
        }
        rules.append(AppModeRule(bundleID: app.bundleID, name: app.name, mode: mode))
        selection = [app.bundleID]
    }

    /// An .app picked in the open panel. Returns false if it has no bundle identifier.
    @discardableResult
    func addApp(at url: URL) -> Bool {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return false }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        add(AppCandidate(bundleID: id, name: name, url: url))
        return true
    }

    func addSuggestions() {
        rules.append(contentsOf: missingSuggestions)
    }

    func removeSelected() {
        rules.removeAll { selection.contains($0.bundleID) }
        selection = []
    }

    func setMode(_ mode: ModeID, for bundleID: String) {
        guard let index = rules.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        rules[index].mode = mode
    }

    func modeBinding(for bundleID: String) -> Binding<ModeID> {
        Binding(get: { self.rules.first(where: { $0.bundleID == bundleID })?.mode ?? .tidy },
                set: { self.setMode($0, for: bundleID) })
    }
}

// MARK: - Glossary

@MainActor
final class GlossaryViewModel: ObservableObject {
    /// The editor's text.
    @Published var text: String
    /// What is on disk.
    @Published private(set) var savedText: String
    @Published private(set) var counts: GlossaryTermCounts
    @Published private(set) var lastSaved: Date? = nil
    @Published var errorMessage: String? = nil

    /// Counts terms in glossary text (wiring: Core's glossary parser).
    var parse: @MainActor (String) -> GlossaryTermCounts
    /// Writes glossary.md. Throw to show an error.
    var save: @MainActor (String) throws -> Void
    /// Where glossary.md lives, for "Show in Finder".
    var fileURL: URL?
    var revealInFinder: @MainActor (URL) -> Void

    private var cancellables: Set<AnyCancellable> = []

    init(text: String = "", fileURL: URL? = nil,
         parse: @escaping @MainActor (String) -> GlossaryTermCounts = { _ in .empty },
         save: @escaping @MainActor (String) throws -> Void = { _ in },
         revealInFinder: @escaping @MainActor (URL) -> Void = { _ in }) {
        self.text = text
        self.savedText = text
        self.fileURL = fileURL
        self.parse = parse
        self.save = save
        self.revealInFinder = revealInFinder
        self.counts = parse(text)

        $text
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.counts = self.parse(value)
            }
            .store(in: &cancellables)
    }

    var isDirty: Bool { text != savedText }

    /// Wiring: the file was (re)loaded from disk.
    func load(_ text: String) {
        self.text = text
        savedText = text
        counts = parse(text)
        errorMessage = nil
    }

    func saveChanges() {
        do {
            try save(text)
            savedText = text
            lastSaved = Date()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save the glossary: \(error.localizedDescription)"
        }
    }

    func revert() {
        text = savedText
        counts = parse(savedText)
        errorMessage = nil
    }

    func showInFinder() {
        if let fileURL { revealInFinder(fileURL) }
    }

    /// The example shown in the help popover (PLAN §6.1).
    static let formatExample = """
    ## Terms
    - **CORSIA** — Carbon Offsetting and Reduction Scheme for International Aviation
      - heard: core sea, corsair
    - **My Supply** — heard: my supplies

    ## People
    - **Siobhán Murphy** — heard: shiv on

    ## Patterns
    - **AB-{n}** — Linear ticket IDs
      - heard: a b {n}, AB {n}

    ## Style
    - Use British English.
    """
}

// MARK: - Privacy & Storage

@MainActor
final class PrivacyViewModel: ObservableObject {
    struct Actions {
        var setAudioRetention: @MainActor (AudioRetention) -> Void = { _ in }
        /// Reveal ~/Library/Application Support/devshout in Finder.
        var showInFinder: @MainActor () -> Void = {}
        /// Delete every recording and its text. The view asks for confirmation first.
        var deleteAllHistory: @MainActor () -> Void = {}
    }

    @Published var audioRetention: AudioRetention {
        didSet { if !isSyncing, audioRetention != oldValue { actions.setAudioRetention(audioRetention) } }
    }
    /// Bytes used by recordings, when known.
    @Published var storageUsed: Int64?
    @Published var recordingCount: Int?
    var actions: Actions

    private var isSyncing = false

    init(audioRetention: AudioRetention = .days30, storageUsed: Int64? = nil, recordingCount: Int? = nil,
         actions: Actions = Actions()) {
        self.audioRetention = audioRetention
        self.storageUsed = storageUsed
        self.recordingCount = recordingCount
        self.actions = actions
    }

    func sync(_ change: () -> Void) {
        isSyncing = true
        change()
        isSyncing = false
    }

    var storageSummary: String? {
        switch (recordingCount, storageUsed) {
        case let (count?, bytes?): "\(UIFormat.plural(count, "recording")) · \(UIFormat.bytes(bytes))"
        case let (count?, nil): UIFormat.plural(count, "recording")
        case let (nil, bytes?): UIFormat.bytes(bytes)
        case (nil, nil): nil
        }
    }

    func showInFinder() { actions.showInFinder() }
    func deleteAllHistory() { actions.deleteAllHistory() }
}
