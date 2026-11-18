// Global dictation hotkeys (PLAN §3.1 step 1, §7.6), built on KeyboardShortcuts 3.1 (Carbon RegisterEventHotKey,
// so no Input Monitoring permission is needed).
//
// Unverified on macOS (written on Linux against the KeyboardShortcuts 3.1.0 sources):
// - That Carbon delivers a key-up for the hotkey when ⌥ is released before Space. Carbon hot keys don't
//   auto-repeat (KeyboardShortcuts synthesises repeats with timers, and drops raw repeats), so a second key-down
//   for a key we think is held means its key-up was missed, and the classifier replays it
//   (`repeatsPossible: false`). If Carbon did repeat, a long hold would stop at the first repeat.
// - ⌥⌘Space is also macOS's default for "Show Finder search window"; if the system keeps it, the recorder in
//   Settings lets the user pick another.
// - Esc is registered as a plain Carbon hotkey only while recording, so it's swallowed system-wide then.

import AppKit
import DevshoutCore
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// ⌥Space: dictate in the frontmost app's default mode (falls back to the global default).
    public static let dictate = Self("dictate", initial: .init(.space, modifiers: [.option]))
    /// ⌥⇧Space: dictate in Structure.
    public static let dictateStructure = Self("dictateStructure", initial: .init(.space, modifiers: [.option, .shift]))
    /// ⌥⌘Space: dictate in Raw.
    public static let dictateRaw = Self("dictateRaw", initial: .init(.space, modifiers: [.option, .command]))
    /// No default: dictate in Tidy (for people who change the global default).
    public static let dictateTidy = Self("dictateTidy")
}

/// The dictation hotkeys: the four fixed ones, and one for each mode the user made (Settings → Modes).
/// Use `name` with `KeyboardShortcuts.Recorder(_:name:)` in Settings and onboarding.
public enum DictationHotkey: Sendable, Hashable {
    case dictate, dictateStructure, dictateRaw, dictateTidy
    /// A custom mode's own hotkey. It has no shortcut until the user records one.
    case custom(ModeID)

    /// The hotkeys that always exist. Their names are fixed, so shortcuts stored under them keep working.
    public static let builtIns: [DictationHotkey] = [.dictate, .dictateStructure, .dictateRaw, .dictateTidy]

    /// A mode's own hotkey.
    public init(mode: ModeID) {
        switch mode {
        case .structure: self = .dictateStructure
        case .raw: self = .dictateRaw
        case .tidy: self = .dictateTidy
        default: self = .custom(mode)
        }
    }

    public var name: KeyboardShortcuts.Name {
        switch self {
        case .dictate: .dictate
        case .dictateStructure: .dictateStructure
        case .dictateRaw: .dictateRaw
        case .dictateTidy: .dictateTidy
        // Made from the mode's id (`ModeID.hotkeyName`), with no initial shortcut.
        case .custom(let mode): KeyboardShortcuts.Name(mode.hotkeyName)
        }
    }

    /// The mode this hotkey forces, or nil for "the app's default mode" (resolved by the mode router).
    public var mode: ModeID? {
        switch self {
        case .dictate: nil
        case .dictateStructure: .structure
        case .dictateRaw: .raw
        case .dictateTidy: .tidy
        case .custom(let mode): mode
        }
    }

    /// Label for Settings and onboarding. A custom mode's own name isn't known here.
    public var title: String {
        switch self {
        case .dictate: "Dictate in the app's default mode"
        case .dictateStructure: "Dictate in Structure"
        case .dictateRaw: "Dictate in Raw"
        case .dictateTidy: "Dictate in Tidy"
        case .custom: "Dictate in this mode"
        }
    }
}

/// A raw hotkey event, before tap/hold classification.
public struct HotkeyEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case down, up }
    public var hotkey: DictationHotkey
    public var kind: Kind
    /// `ProcessInfo.systemUptime` when the event was handled.
    public var timestamp: TimeInterval

    public init(hotkey: DictationHotkey, kind: Kind, timestamp: TimeInterval) {
        self.hotkey = hotkey
        self.kind = kind
        self.timestamp = timestamp
    }
}

/// What the dictation pipeline should do: `.start(hotkey)`, `.stop`, `.switchMode(hotkey)` or `.cancel` (Esc).
public typealias HotkeyAction = TapHoldAction<DictationHotkey>

/// Registers the dictation hotkeys, classifies taps and holds, and emits actions.
///
/// Usage:
/// ```swift
/// let hotkeys = HotkeyCenter(behaviour: .tapToggleHoldToTalk)
/// hotkeys.onAction = { action in … }        // or: for await action in hotkeys.actions() { … }
/// hotkeys.start()
/// // When a recording ends without a hotkey (overlay Stop/Cancel, an error):
/// hotkeys.recordingEnded()
/// ```
/// Esc is registered only between `.start` and the end of that recording.
///
/// Custom modes: call `setCustomModes(_:)` with the ids in the settings at launch and after every change. Their
/// hotkeys get the same handlers as the fixed four, so tap-to-toggle, hold-to-talk and switching mode while
/// recording behave the same.
///
/// The centre keeps its own idea of "recording". Whenever the pipeline's state differs from it (it refused a
/// `.start` because it was still busy, the overlay's Stop or Cancel was used, a stage failed), call
/// `recordingEnded()` so the next press starts rather than stops.
@MainActor
public final class HotkeyCenter {
    public var behaviour: TapHoldBehaviour {
        get { classifier.behaviour }
        set { classifier.behaviour = newValue }
    }

    /// Called for every classified action, on the main actor.
    public var onAction: ((HotkeyAction) -> Void)?
    /// Called for every raw key-down and key-up, on the main actor (for diagnostics or the overlay).
    public var onEvent: ((HotkeyEvent) -> Void)?

    public var isRecording: Bool { classifier.isRecording }
    public var activeHotkey: DictationHotkey? { classifier.activeTrigger }
    public private(set) var isStarted = false

    /// The custom modes whose hotkeys are handled, as last given to `setCustomModes`.
    public private(set) var customModes: [ModeID] = []

    private var classifier: TapHoldClassifier<DictationHotkey>
    private var continuations: [UUID: AsyncStream<HotkeyAction>.Continuation] = [:]
    private var escapeTask: Task<Void, Never>?

    public init(behaviour: TapHoldBehaviour = .tapToggleHoldToTalk,
                holdThreshold: TimeInterval = TapHoldClassifier<DictationHotkey>.defaultHoldThreshold) {
        classifier = TapHoldClassifier(behaviour: behaviour, holdThreshold: holdThreshold)
    }

    /// Registers the handlers. Safe to call again.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        for hotkey in allHotkeys { register(hotkey) }
    }

    /// The custom modes that exist now. Hotkeys of new ones are registered (once `start()` has run); for ones
    /// that have gone, the handlers are removed and the stored shortcut is forgotten, so a deleted mode's key
    /// combination is free again and nothing is left behind in UserDefaults.
    public func setCustomModes(_ modes: [ModeID]) {
        var next: [ModeID] = []
        for mode in modes where mode.isCustom && !next.contains(mode) { next.append(mode) }
        let removed = customModes.filter { !next.contains($0) }
        let added = next.filter { !customModes.contains($0) }
        customModes = next
        for mode in removed {
            let name = DictationHotkey.custom(mode).name
            KeyboardShortcuts.removeHandler(for: name)
            KeyboardShortcuts.reset(name)
        }
        if isStarted {
            for mode in added { register(.custom(mode)) }
        }
    }

    private var allHotkeys: [DictationHotkey] {
        DictationHotkey.builtIns + customModes.map { .custom($0) }
    }

    private func register(_ hotkey: DictationHotkey) {
        let name = hotkey.name
        KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
            self?.handle(hotkey, .down)
        }
        KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
            self?.handle(hotkey, .up)
        }
    }

    /// Unregisters the handlers and Esc, and forgets the state.
    public func stop() {
        guard isStarted else { return }
        isStarted = false
        for hotkey in allHotkeys {
            KeyboardShortcuts.removeHandler(for: hotkey.name)
        }
        setEscapeEnabled(false)
        classifier.reset()
    }

    /// A stream of actions. Several streams may be open at once; each ends when its consumer stops iterating.
    public func actions() -> AsyncStream<HotkeyAction> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<HotkeyAction>.makeStream(bufferingPolicy: .unbounded)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.continuations[id] = nil }
        }
        return stream
    }

    /// The recording ended without a hotkey (the overlay's buttons, an error, the pipeline finishing). Clears the
    /// recording state and drops the Esc hotkey; held keys are still tracked so their key-ups do nothing.
    public func recordingEnded() {
        classifier.recordingEnded()
        setEscapeEnabled(false)
    }

    /// Feed an event directly (used by the hotkey handlers; handy for a debug menu).
    public func handle(_ hotkey: DictationHotkey, _ kind: HotkeyEvent.Kind,
                       at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        onEvent?(HotkeyEvent(hotkey: hotkey, kind: kind, timestamp: timestamp))
        let action: HotkeyAction?
        switch kind {
        case .down:
            // Carbon hot keys never auto-repeat, so a second key-down means a missed key-up (see TapHoldClassifier).
            action = classifier.keyDown(hotkey, at: timestamp, repeatsPossible: false)
        case .up:
            action = classifier.keyUp(hotkey, at: timestamp)
        }
        if let action { emit(action) }
    }

    // MARK: - Private

    private func emit(_ action: HotkeyAction) {
        switch action {
        case .start: setEscapeEnabled(true)
        case .stop, .cancel: setEscapeEnabled(false)
        case .switchMode: break
        }
        onAction?(action)
        for continuation in continuations.values { continuation.yield(action) }
    }

    private func handleEscape() {
        if let action = classifier.cancel() { emit(action) }
    }

    private func setEscapeEnabled(_ enabled: Bool) {
        if enabled {
            guard escapeTask == nil else { return }
            // Building the stream registers the Carbon hotkey; cancelling the task ends the stream, which
            // unregisters it (KeyboardShortcuts' onTermination).
            let events = KeyboardShortcuts.events(for: KeyboardShortcuts.Shortcut(.escape))
            escapeTask = Task { @MainActor [weak self] in
                for await event in events where event == .keyDown {
                    self?.handleEscape()
                }
            }
        } else {
            escapeTask?.cancel()
            escapeTask = nil
        }
    }
}
