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

/// Settings → Modes: the three built-in modes (model, timeout, edited instructions) and the user's own modes
/// (added blank or from a template, renamed, duplicated, deleted, reordered).
@MainActor
final class ModesSettingsViewModel: ObservableObject {
    struct Actions {
        /// Persist one built-in mode's config.
        var saveBuiltIn: @MainActor (ModeConfig) -> Void = { _ in }
        /// Persist the user's modes: the whole list, in order, after any edit, addition, move or deletion.
        /// The wiring also drops what pointed at a deleted mode (its hotkey, the default mode, per-app rules).
        var saveCustomModes: @MainActor ([CustomMode]) -> Void = { _ in }
    }

    static let timeoutRange: ClosedRange<Double> = 5...120
    static let timeoutStep: Double = 5

    @Published var configs: [ModeID: ModeConfig]
    /// The user's modes, in the order they are listed.
    @Published var customModes: [CustomMode]
    @Published var selectedMode: ModeID = .tidy
    /// The built-in instructions per mode (from Core's prompt builder), shown when there is no custom text.
    var defaultInstructions: [ModeID: String]
    /// The ready-made modes offered by the Add menu.
    var templates: [CustomModeTemplate]
    var actions: Actions

    init(configs: [ModeID: ModeConfig] = ModeConfig.defaults, customModes: [CustomMode] = [],
         defaultInstructions: [ModeID: String] = [:], templates: [CustomModeTemplate] = CustomModeTemplate.all,
         actions: Actions = Actions()) {
        self.configs = configs
        self.customModes = customModes
        self.defaultInstructions = defaultInstructions
        self.templates = templates
        self.actions = actions
    }

    // MARK: The list

    /// Every mode, as listed: the built-ins, then the user's.
    var modes: [ModeDescriptor] { ModeDescriptor.builtIns + customModes.map(ModeDescriptor.init) }

    /// The mode the detail pane shows. If the selected mode has gone (deleted here or elsewhere), Tidy.
    var selected: ModeDescriptor {
        modes.first { $0.id == selectedMode } ?? .tidy
    }

    func customMode(_ id: ModeID) -> CustomMode? { customModes.first { $0.id == id } }

    var canDeleteSelected: Bool { customMode(selected.id) != nil }
    /// Raw has no instructions to copy.
    var canDuplicateSelected: Bool { selected.usesClaude }

    // MARK: Built-in modes

    func config(for mode: ModeID) -> ModeConfig {
        if let custom = customMode(mode) { return custom.config }
        return configs[mode] ?? ModeConfig.defaults[mode] ?? ModeConfig(id: mode, claudeModel: "haiku", timeout: 20)
    }

    /// Changes a built-in mode's config.
    func update(_ mode: ModeID, _ change: (inout ModeConfig) -> Void) {
        guard mode.isBuiltIn else { return }
        var config = config(for: mode)
        let before = config
        change(&config)
        guard config != before else { return }
        configs[mode] = config
        actions.saveBuiltIn(config)
    }

    // MARK: The user's modes

    /// Changes one of the user's modes.
    func updateCustom(_ id: ModeID, _ change: (inout CustomMode) -> Void) {
        guard let index = customModes.firstIndex(where: { $0.id == id }) else { return }
        var mode = customModes[index]
        change(&mode)
        mode.id = id
        guard mode != customModes[index] else { return }
        customModes[index] = mode
        actions.saveCustomModes(customModes)
    }

    private func unusedName(_ name: String) -> String {
        CustomMode.unusedName(name, among: modes.map(\.name))
    }

    private func append(_ mode: CustomMode) -> ModeID {
        customModes.append(mode)
        selectedMode = mode.id
        actions.saveCustomModes(customModes)
        return mode.id
    }

    /// Adds an empty mode, selects it and returns its id.
    @discardableResult
    func addBlank() -> ModeID {
        append(CustomMode(name: unusedName(CustomMode.defaultName)))
    }

    /// Adds a copy of a template, selects it and returns its id.
    @discardableResult
    func add(_ template: CustomModeTemplate) -> ModeID {
        append(template.makeMode(name: unusedName(template.name)))
    }

    /// Copies a mode into a new one of the user's: its instructions, model, timeout and look. For Tidy and
    /// Structure the copy starts from the instructions they use now. Raw has nothing to copy.
    @discardableResult
    func duplicate(_ id: ModeID) -> ModeID? {
        let source = modes.descriptor(for: id)
        guard source.exists, source.usesClaude else { return nil }
        let config = config(for: id)
        let copy = CustomMode(name: unusedName(ModesText.copyName(of: source.name)),
                              instructions: customMode(id)?.instructions ?? instructions(for: id),
                              claudeModel: config.claudeModel.isEmpty ? CustomMode.defaultClaudeModel : config.claudeModel,
                              timeout: clampedTimeout(config.timeout),
                              symbol: source.symbol, tint: source.tint)
        guard let index = customModes.firstIndex(where: { $0.id == id }) else { return append(copy) }
        customModes.insert(copy, at: index + 1)
        selectedMode = copy.id
        actions.saveCustomModes(customModes)
        return copy.id
    }

    /// Deletes one of the user's modes and selects its neighbour. The view asks for confirmation first.
    func delete(_ id: ModeID) {
        guard let index = customModes.firstIndex(where: { $0.id == id }) else { return }
        customModes.remove(at: index)
        if selectedMode == id {
            selectedMode = customModes.indices.contains(index) ? customModes[index].id
                : customModes.last?.id ?? .tidy
        }
        actions.saveCustomModes(customModes)
    }

    /// Drag to reorder (`ForEach.onMove`).
    func move(from source: IndexSet, to destination: Int) {
        let before = customModes
        // The same result as `Array.move(fromOffsets:toOffset:)`, without needing SwiftUI here.
        let moving = source.sorted().map { customModes[$0] }
        let shift = source.filter { $0 < destination }.count
        for index in source.sorted().reversed() { customModes.remove(at: index) }
        customModes.insert(contentsOf: moving, at: min(max(destination - shift, 0), customModes.count))
        if customModes != before { actions.saveCustomModes(customModes) }
    }

    private func clampedTimeout(_ value: Double) -> Double {
        min(max(value, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
    }

    // MARK: Bindings for the views

    func modelBinding(for mode: ModeID) -> Binding<String> {
        // Aliases are matched in lower case so "Haiku" still selects the Haiku row.
        Binding(get: {
                    let model = self.config(for: mode).claudeModel
                    return ClaudeModelOption(alias: model)?.rawValue ?? model
                },
                set: { value in
                    if mode.isBuiltIn {
                        self.update(mode) { $0.claudeModel = value }
                    } else {
                        self.updateCustom(mode) { $0.claudeModel = value }
                    }
                })
    }

    func timeoutBinding(for mode: ModeID) -> Binding<Double> {
        Binding(get: { self.config(for: mode).timeout },
                set: { value in
                    let clamped = self.clampedTimeout(value)
                    if mode.isBuiltIn {
                        self.update(mode) { $0.timeout = clamped }
                    } else {
                        self.updateCustom(mode) { $0.timeout = clamped }
                    }
                })
    }

    /// The text in a built-in mode's instructions editor: the custom text, or the default when there is none.
    /// Typing text equal to the default clears the custom value.
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
        if let custom = customMode(mode) { return custom.instructions }
        return config(for: mode).customInstructions ?? defaultInstructions[mode] ?? ""
    }

    func hasCustomInstructions(for mode: ModeID) -> Bool { config(for: mode).customInstructions != nil }

    func resetInstructions(for mode: ModeID) {
        update(mode) { $0.customInstructions = nil }
    }

    /// The name field of one of the user's modes. What is typed is kept as typed (the list and the chips show it
    /// trimmed, and "Untitled mode" while it is empty), but never longer than a chip can show.
    func nameBinding(for id: ModeID) -> Binding<String> {
        Binding(get: { self.customMode(id)?.name ?? "" },
                set: { value in
                    let oneLine = value.replacingOccurrences(of: "\n", with: " ")
                    self.updateCustom(id) { $0.name = String(oneLine.prefix(CustomMode.maximumNameLength)) }
                })
    }

    func customInstructionsBinding(for id: ModeID) -> Binding<String> {
        Binding(get: { self.customMode(id)?.instructions ?? "" },
                set: { value in self.updateCustom(id) { $0.instructions = value } })
    }

    func symbolBinding(for id: ModeID) -> Binding<ModeSymbol> {
        Binding(get: { self.customMode(id)?.symbol ?? CustomMode.defaultSymbol },
                set: { value in self.updateCustom(id) { $0.symbol = value } })
    }

    func tintBinding(for id: ModeID) -> Binding<ModeTint> {
        Binding(get: { self.customMode(id)?.tint ?? CustomMode.defaultTint },
                set: { value in self.updateCustom(id) { $0.tint = value } })
    }
}

// MARK: - Apps

@MainActor
final class AppsSettingsViewModel: ObservableObject {
    @Published var rules: [AppModeRule] {
        didSet { if !isSyncing, rules != oldValue { onChange(rules) } }
    }
    @Published var selection: Set<AppModeRule.ID> = []
    /// The modes an app can be given: the built-ins, then the user's own. Wiring keeps it current.
    @Published var modes: [ModeDescriptor] = ModeDescriptor.builtIns
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

    /// Wiring: glossary.md was changed and saved from outside the editor ("Add correction…" in History) and now
    /// holds `saved`. The editor shows it; when it has unsaved edits they are kept, with the same `edit` made to
    /// them, and stay unsaved.
    func savedElsewhere(_ saved: String, edit: (String) -> String) {
        text = isDirty ? edit(text) : saved
        savedText = saved
        counts = parse(text)
        lastSaved = Date()
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

// MARK: - History

@MainActor
final class HistoryViewModel: ObservableObject {
    struct Actions {
        /// Read the recordings from disk again.
        var reload: @MainActor () -> Void = {}
        /// Delete one recording (audio and text). The view asks for confirmation first.
        var delete: @MainActor (UUID) -> Void = { _ in }
        var showInFinder: @MainActor (UUID) -> Void = { _ in }
        /// Play the recording's audio from the start. The wiring answers with `playbackStarted`,
        /// `playbackUnavailable` and, at the end of the file, `playbackEnded`.
        var play: @MainActor (UUID) -> Void = { _ in }
        /// Stop whatever is playing. Called whether or not anything is, so it must be safe at any time.
        var stopPlayback: @MainActor () -> Void = {}
        /// Send the recording's transcript to Claude again in this mode and add the result to the recording as a
        /// new version. Nothing is pasted. The wiring answers with `rerunStarted`, then `rerunFinished`,
        /// `rerunFailed` or `rerunCancelled`.
        var rerun: @MainActor (UUID, ModeID) -> Void = { _, _ in }
        var cancelRerun: @MainActor (UUID) -> Void = { _ in }
        /// Add `heard` to the glossary as a mishearing of `term` (on its entry, or on a new one of this kind) and
        /// save glossary.md. Throws when the file can't be read or written.
        var addCorrection: @MainActor (_ heard: String, _ term: String, _ kind: GlossaryEditor.CorrectionKind) throws
            -> GlossaryEditor.CorrectionOutcome = { _, _, _ in .nothingToAdd }
        /// The glossary's spelling of the entry a correction for this term would go on, if it has one.
        var existingGlossaryTerm: @MainActor (String) -> String? = { _ in nil }
    }

    /// The modes that exist: the built-ins, then the user's own. Wiring keeps it current.
    @Published var modes: [ModeDescriptor] = ModeDescriptor.builtIns

    /// The modes a recording can be re-run in (the ones that use Claude).
    var rerunModes: [ModeDescriptor] { modes.filter(\.usesClaude) }

    /// How to show a recording's mode: as it is now, or, for a custom mode that was deleted, under the name the
    /// recording kept (else "Deleted mode").
    func descriptor(for recording: Recording) -> ModeDescriptor {
        modes.descriptor(for: recording.mode, storedName: recording.modeName)
    }

    /// Newest first.
    @Published var recordings: [Recording] {
        didSet { stopPlaybackUnlessSelected() }
    }
    /// The search field's text. Blank shows everything.
    @Published var searchText: String {
        didSet { stopPlaybackUnlessSelected() }
    }
    /// The row picked in the list. Nil (nothing picked yet, or the picked one was filtered out or deleted) shows
    /// the first visible recording.
    @Published var selection: UUID? {
        didSet { stopPlaybackUnlessSelected() }
    }
    @Published private(set) var playback: HistoryPlayback = .idle
    /// Re-runs in progress, and the last failure, per recording.
    @Published private(set) var reruns: [UUID: HistoryRerunState] = [:]
    /// What the last "Add correction…" did.
    @Published private(set) var correctionNotice: HistoryCorrectionNotice?
    var actions: Actions

    init(recordings: [Recording] = [], searchText: String = "", selection: UUID? = nil, actions: Actions = Actions()) {
        self.recordings = recordings
        self.searchText = searchText
        self.selection = selection
        self.actions = actions
    }

    /// The recordings that match the search, newest first.
    var visibleRecordings: [Recording] { recordings.matching(search: searchText) }

    /// The recording the detail pane shows.
    var selectedRecording: Recording? {
        let visible = visibleRecordings
        return visible.first { $0.id == selection } ?? visible.first
    }

    func reload() { actions.reload() }
    func delete(_ id: UUID) { actions.delete(id) }
    func showInFinder(_ id: UUID) { actions.showInFinder(id) }

    // MARK: Playback

    func isPlaying(_ id: UUID) -> Bool { playback == .playing(id) }

    /// Why this recording's audio couldn't be played, after a try that failed.
    func playbackProblem(for id: UUID) -> String? {
        if case .unavailable(id, let message) = playback { return message }
        return nil
    }

    /// The Play / Stop button.
    func togglePlayback(_ id: UUID) {
        if isPlaying(id) {
            stopPlayback()
        } else {
            playback = .idle
            actions.play(id)
        }
    }

    /// Stops the audio. Called from explicit events as well as the Stop button: another recording is shown, the
    /// Settings window closes or moves to another tab, a dictation starts.
    func stopPlayback() {
        actions.stopPlayback()
        if case .playing = playback { playback = .idle }
    }

    /// The audio belongs to the recording on show: anything else on show means silence (and no stale message).
    private func stopPlaybackUnlessSelected() {
        let shown = selectedRecording?.id
        switch playback {
        case .idle: break
        case .playing(let id): if id != shown { stopPlayback() }
        case .unavailable(let id, _): if id != shown { playback = .idle }
        }
        // Likewise what was said about a glossary correction made from another recording.
        if let notice = correctionNotice, notice.recordingID != shown { correctionNotice = nil }
    }

    // Wiring → model.

    func playbackStarted(_ id: UUID) {
        playback = .playing(id)
        // Finding the file took a moment: another recording may be on show by now.
        stopPlaybackUnlessSelected()
    }

    /// The file played to its end, or the wiring stopped it.
    func playbackEnded(_ id: UUID) {
        if isPlaying(id) { playback = .idle }
    }

    func playbackUnavailable(_ id: UUID, message: String) {
        playback = .unavailable(id, message: message)
        stopPlaybackUnlessSelected()
    }

    // MARK: Re-run

    func isRerunning(_ id: UUID) -> Bool {
        if case .running = reruns[id] { return true }
        return false
    }

    /// Whether there is a transcript to send and no re-run of it already going.
    func canRerun(_ recording: Recording) -> Bool {
        guard let transcript = recording.transcript else { return false }
        return !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRerunning(recording.id)
    }

    func rerun(_ id: UUID, mode: ModeID) {
        guard !isRerunning(id) else { return }
        reruns[id] = nil
        actions.rerun(id, mode)
    }

    func cancelRerun(_ id: UUID) { actions.cancelRerun(id) }

    // Wiring → model.

    func rerunStarted(_ id: UUID, mode: ModeID, model: String) {
        reruns[id] = .running(mode: modes.descriptor(for: mode), model: model)
    }

    /// The recording as saved, with its new version.
    func rerunFinished(_ updated: Recording) {
        reruns[updated.id] = nil
        if let index = recordings.firstIndex(where: { $0.id == updated.id }) { recordings[index] = updated }
    }

    func rerunFailed(_ id: UUID, mode: ModeID, message: String) {
        reruns[id] = .failed(mode: modes.descriptor(for: mode), message: message)
    }

    func rerunCancelled(_ id: UUID) {
        reruns[id] = nil
    }

    // MARK: Glossary corrections

    /// Whether the two fields of "Add correction…" make a correction: both filled in, and not the same.
    func canAddCorrection(heard: String, term: String) -> Bool {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        return !heard.isEmpty && !term.isEmpty && heard.lowercased() != term.lowercased()
    }

    /// The glossary's spelling of the entry the correction would go on, or nil when it would make a new one.
    func existingGlossaryTerm(matching term: String) -> String? { actions.existingGlossaryTerm(term) }

    /// Adds the correction to the glossary and says what happened in the pane of the recording it was made from.
    func addCorrection(heard: String, term: String, kind: GlossaryEditor.CorrectionKind, from recordingID: UUID) {
        guard canAddCorrection(heard: heard, term: term) else { return }
        do {
            let outcome = try actions.addCorrection(heard, term, kind)
            correctionNotice = HistoryCorrectionNotice(
                recordingID: recordingID, text: HistoryText.correction(outcome, heard: heard),
                tone: outcome == .nothingToAdd ? .warning : .positive)
        } catch {
            correctionNotice = HistoryCorrectionNotice(
                recordingID: recordingID, text: HistoryText.correctionNotSaved(error.localizedDescription),
                tone: .critical)
        }
    }

    func correctionNotice(for id: UUID) -> HistoryCorrectionNotice? {
        correctionNotice?.recordingID == id ? correctionNotice : nil
    }
}
