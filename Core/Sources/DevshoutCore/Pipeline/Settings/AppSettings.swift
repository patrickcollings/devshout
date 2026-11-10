import Foundation

/// How the dictation hotkey behaves (PLAN §3.1, §7.4).
public enum HotkeyBehaviour: String, Codable, Sendable, CaseIterable, Hashable {
    /// A tap (< 0.35 s) toggles recording; holding the key is push-to-talk.
    case tapToggleHoldToTalk
    /// Press to start, press again to stop.
    case toggleOnly
    /// Record only while the key is held down.
    case holdOnly

    public var displayName: String {
        switch self {
        case .tapToggleHoldToTalk: "Tap to toggle, hold to talk"
        case .toggleOnly: "Toggle only"
        case .holdOnly: "Hold to talk only"
        }
    }
}

/// How the finished text reaches the focused app (PLAN §3.3).
public enum PasteMethod: String, Codable, Sendable, CaseIterable, Hashable {
    /// Clipboard plus a synthetic ⌘V.
    case commandV
    /// Clipboard plus "type via Accessibility" (`kAXSelectedTextAttribute`), for apps that ignore ⌘V.
    case accessibility

    public var displayName: String {
        switch self {
        case .commandV: "Paste with ⌘V"
        case .accessibility: "Type via Accessibility"
        }
    }
}

/// A pre-filled row for Settings → Apps.
public struct AppModeSuggestion: Sendable, Hashable, Identifiable {
    public var bundleID: String
    public var name: String
    public var mode: ModeID
    public var id: String { bundleID }

    public init(bundleID: String, name: String, mode: ModeID) {
        self.bundleID = bundleID
        self.name = name
        self.mode = mode
    }
}

/// Everything in `settings.json`. Decoding is tolerant: a missing key takes its default, and an unknown key or a
/// value of the wrong shape is ignored, so an old or hand-edited file never stops the app from starting.
public struct AppSettings: Codable, Sendable, Hashable {
    /// Bumped when a migration is needed. Older files are read with the same tolerant rules.
    public static let currentVersion = 1

    public var version: Int
    public var engine: EngineID
    /// The mode used by the generic hotkey when the frontmost app has no per-app mode.
    public var defaultMode: ModeID
    /// Per-mode Claude settings. Always contains every `ModeID` after decoding.
    public var modes: [ModeID: ModeConfig]
    /// Bundle identifier → mode, for the generic hotkey.
    public var perAppModes: [String: ModeID]
    public var hotkeyBehaviour: HotkeyBehaviour
    public var pasteMethod: PasteMethod
    public var soundsEnabled: Bool
    public var showLivePreview: Bool
    /// Days to keep `audio.wav` files. `nil` or ≤ 0 keeps audio for ever. Text is always kept.
    public var audioRetentionDays: Int?
    /// A path to the `claude` binary chosen in Settings → Claude, overriding the search.
    public var claudePathOverride: String?
    /// Core Audio device UID of the chosen microphone; `nil` follows the system input.
    public var inputDeviceUID: String?
    /// Apply the glossary's deterministic fixes (known mishearings, ticket IDs) in every mode, Raw included.
    public var applyGlossaryFixes: Bool

    public init(
        version: Int = AppSettings.currentVersion,
        engine: EngineID = .parakeetV3,
        defaultMode: ModeID = .tidy,
        modes: [ModeID: ModeConfig] = ModeConfig.defaults,
        perAppModes: [String: ModeID] = [:],
        hotkeyBehaviour: HotkeyBehaviour = .tapToggleHoldToTalk,
        pasteMethod: PasteMethod = .commandV,
        soundsEnabled: Bool = true,
        showLivePreview: Bool = true,
        audioRetentionDays: Int? = 30,
        claudePathOverride: String? = nil,
        inputDeviceUID: String? = nil,
        applyGlossaryFixes: Bool = true
    ) {
        self.version = version
        self.engine = engine
        self.defaultMode = defaultMode
        self.modes = modes
        self.perAppModes = perAppModes
        self.hotkeyBehaviour = hotkeyBehaviour
        self.pasteMethod = pasteMethod
        self.soundsEnabled = soundsEnabled
        self.showLivePreview = showLivePreview
        self.audioRetentionDays = audioRetentionDays
        self.claudePathOverride = claudePathOverride
        self.inputDeviceUID = inputDeviceUID
        self.applyGlossaryFixes = applyGlossaryFixes
    }

    public static let defaults = AppSettings()

    /// The config for a mode, falling back to the built-in default. Its timeout is always usable
    /// (`ModeConfig.effectiveTimeout`), however the settings were made.
    public func config(for mode: ModeID) -> ModeConfig {
        var config = modes[mode] ?? ModeConfig.defaults[mode] ?? ModeConfig(id: mode, claudeModel: "", timeout: 0)
        config.timeout = config.effectiveTimeout
        return config
    }

    /// Suggestions shown (but not applied) in Settings → Apps.
    public static let perAppModeSuggestions: [AppModeSuggestion] = [
        AppModeSuggestion(bundleID: "com.apple.Terminal", name: "Terminal", mode: .structure),
        AppModeSuggestion(bundleID: "com.googlecode.iterm2", name: "iTerm2", mode: .structure),
        AppModeSuggestion(bundleID: "com.mitchellh.ghostty", name: "Ghostty", mode: .structure),
        AppModeSuggestion(bundleID: "dev.warp.Warp-Stable", name: "Warp", mode: .structure),
        AppModeSuggestion(bundleID: "com.microsoft.VSCode", name: "VS Code", mode: .structure),
        AppModeSuggestion(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor", mode: .structure),
        AppModeSuggestion(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", mode: .tidy),
        AppModeSuggestion(bundleID: "com.apple.mail", name: "Mail", mode: .tidy),
        AppModeSuggestion(bundleID: "com.apple.Notes", name: "Notes", mode: .tidy),
    ]

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case version, engine, defaultMode, modes, perAppModes, hotkeyBehaviour, pasteMethod, soundsEnabled,
             showLivePreview, audioRetentionDays, claudePathOverride, inputDeviceUID, applyGlossaryFixes
    }

    public init(from decoder: any Decoder) throws {
        let d = AppSettings.defaults
        // A top level that isn't an object (e.g. `[]`) still yields defaults rather than an error.
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = d
            return
        }
        version = c.lenient(Int.self, .version) ?? d.version
        engine = c.lenient(EngineID.self, .engine) ?? d.engine
        defaultMode = c.lenient(ModeID.self, .defaultMode) ?? d.defaultMode
        hotkeyBehaviour = c.lenient(HotkeyBehaviour.self, .hotkeyBehaviour) ?? d.hotkeyBehaviour
        pasteMethod = c.lenient(PasteMethod.self, .pasteMethod) ?? d.pasteMethod
        soundsEnabled = c.lenient(Bool.self, .soundsEnabled) ?? d.soundsEnabled
        showLivePreview = c.lenient(Bool.self, .showLivePreview) ?? d.showLivePreview
        applyGlossaryFixes = c.lenient(Bool.self, .applyGlossaryFixes) ?? d.applyGlossaryFixes
        claudePathOverride = c.lenient(String.self, .claudePathOverride)
        inputDeviceUID = c.lenient(String.self, .inputDeviceUID)
        // An explicit null means "for ever"; a missing key means the default.
        if c.contains(.audioRetentionDays) {
            audioRetentionDays = c.lenient(Int.self, .audioRetentionDays)
        } else {
            audioRetentionDays = d.audioRetentionDays
        }

        var modes = ModeConfig.defaults
        if let stored = c.lenient([String: PartialModeConfig].self, .modes) {
            for (key, partial) in stored {
                guard let id = ModeID(rawValue: key) else { continue }
                modes[id] = partial.merged(over: modes[id] ?? ModeConfig(id: id, claudeModel: "", timeout: 0))
            }
        }
        self.modes = modes

        var perApp: [String: ModeID] = [:]
        if let stored = c.lenient([String: LenientValue<ModeID>].self, .perAppModes) {
            for (bundleID, value) in stored {
                if let mode = value.value, !bundleID.isEmpty { perApp[bundleID] = mode }
            }
        }
        perAppModes = perApp
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(engine, forKey: .engine)
        try c.encode(defaultMode, forKey: .defaultMode)
        // Keyed by the mode's raw value so the file reads as a JSON object.
        let modesByName = Dictionary(uniqueKeysWithValues: modes.map { ($0.key.rawValue, $0.value) })
        try c.encode(modesByName, forKey: .modes)
        try c.encode(perAppModes.mapValues(\.rawValue), forKey: .perAppModes)
        try c.encode(hotkeyBehaviour, forKey: .hotkeyBehaviour)
        try c.encode(pasteMethod, forKey: .pasteMethod)
        try c.encode(soundsEnabled, forKey: .soundsEnabled)
        try c.encode(showLivePreview, forKey: .showLivePreview)
        // Written explicitly (null = for ever) so a missing key can mean "default".
        if let days = audioRetentionDays {
            try c.encode(days, forKey: .audioRetentionDays)
        } else {
            try c.encodeNil(forKey: .audioRetentionDays)
        }
        try c.encodeIfPresent(claudePathOverride, forKey: .claudePathOverride)
        try c.encodeIfPresent(inputDeviceUID, forKey: .inputDeviceUID)
        try c.encode(applyGlossaryFixes, forKey: .applyGlossaryFixes)
    }
}

/// A `ModeConfig` as stored, with every field optional, merged over the defaults.
struct PartialModeConfig: Decodable {
    var claudeModel: String?
    var timeout: TimeInterval?
    var customInstructions: String?
    var hasCustomInstructions: Bool

    enum CodingKeys: String, CodingKey { case id, claudeModel, timeout, customInstructions }

    init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            claudeModel = nil
            timeout = nil
            customInstructions = nil
            hasCustomInstructions = false
            return
        }
        claudeModel = c.lenient(String.self, .claudeModel)
        timeout = c.lenient(TimeInterval.self, .timeout)
        hasCustomInstructions = c.contains(.customInstructions)
        customInstructions = c.lenient(String.self, .customInstructions)
    }

    func merged(over base: ModeConfig) -> ModeConfig {
        var config = base
        if let claudeModel { config.claudeModel = claudeModel }
        // Clamped: a hand-edited file with a huge timeout used to crash the app at the first clean-up.
        if let timeout, timeout.isFinite, timeout >= 0 { config.timeout = min(timeout, ModeConfig.maximumTimeout) }
        if hasCustomInstructions {
            let trimmed = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            config.customInstructions = trimmed.isEmpty ? nil : customInstructions
        }
        return config
    }
}

/// Decodes a value if it can, else `nil`, without failing the surrounding container.
struct LenientValue<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: any Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

extension KeyedDecodingContainer {
    /// `decodeIfPresent` that swallows type mismatches and unknown enum values, returning `nil`.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(LenientValue<T>.self, forKey: key))?.value
    }
}
