import Foundation
import Testing
@testable import DevshoutCore

func pipelineFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/pipeline"))
    return try Data(contentsOf: url)
}

@Suite struct SettingsTests {
    @Test func defaults() {
        let s = AppSettings()
        #expect(s.engine == .parakeetV3)
        #expect(s.defaultMode == .tidy)
        #expect(s.modes == ModeConfig.defaults)
        #expect(s.perAppModes.isEmpty)
        #expect(s.hotkeyBehaviour == .tapToggleHoldToTalk)
        #expect(s.pasteMethod == .commandV)
        #expect(s.soundsEnabled)
        #expect(s.showLivePreview)
        #expect(s.audioRetentionDays == 30)
        #expect(s.claudePathOverride == nil)
        #expect(s.inputDeviceUID == nil)
        #expect(s.applyGlossaryFixes)
    }

    @Test func suggestions() {
        let byName = Dictionary(uniqueKeysWithValues: AppSettings.perAppModeSuggestions.map { ($0.name, $0) })
        for name in ["Terminal", "iTerm2", "Ghostty", "Warp", "VS Code", "Cursor"] {
            #expect(byName[name]?.mode == .structure, "\(name)")
        }
        for name in ["Slack", "Mail", "Notes"] {
            #expect(byName[name]?.mode == .tidy, "\(name)")
        }
        #expect(byName["Terminal"]?.bundleID == "com.apple.Terminal")
        #expect(byName["Slack"]?.bundleID == "com.tinyspeck.slackmacgap")
        #expect(Set(AppSettings.perAppModeSuggestions.map(\.bundleID)).count == AppSettings.perAppModeSuggestions.count)
    }

    @Test func hugeTimeoutsAreClamped() throws {
        // A hand-edited file: 1e30 s used to crash the app when the session turned it into nanoseconds.
        let json = #"{"modes": {"tidy": {"timeout": 1e30}, "structure": {"timeout": 601}, "raw": {"timeout": -5}}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.modes[.tidy]?.timeout == ModeConfig.maximumTimeout)
        #expect(s.modes[.structure]?.timeout == 600)
        #expect(s.modes[.raw]?.timeout == 0)  // not a valid timeout: the default stays
        // Settings → Modes goes up to 120 s; that and anything else under the limit is kept as it is.
        let fine = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"modes": {"tidy": {"timeout": 120}}}"#.utf8))
        #expect(fine.modes[.tidy]?.timeout == 120)
        #expect(fine.modes[.tidy]?.claudeModel == "haiku")

        // Settings built in code are bounded where they are read.
        var built = AppSettings()
        built.modes[.tidy]?.timeout = .infinity
        built.modes[.structure]?.timeout = .nan
        #expect(built.config(for: .tidy).timeout == 600)
        #expect(built.config(for: .structure).timeout == 0)
        #expect(ModeConfig(id: .tidy, claudeModel: "haiku", timeout: -1).effectiveTimeout == 0)
        #expect(ModeConfig(id: .tidy, claudeModel: "haiku", timeout: 20).effectiveTimeout == 20)
    }

    @Test func roundTrip() throws {
        var s = AppSettings()
        s.engine = .whisperLargeV3Turbo
        s.defaultMode = .structure
        s.modes[.tidy] = ModeConfig(id: .tidy, claudeModel: "sonnet", timeout: 12, customInstructions: "Keep it short.")
        s.perAppModes = ["com.apple.Terminal": .structure, "com.apple.mail": .raw]
        s.hotkeyBehaviour = .toggleOnly
        s.pasteMethod = .accessibility
        s.soundsEnabled = false
        s.showLivePreview = false
        s.audioRetentionDays = nil
        s.claudePathOverride = "/opt/homebrew/bin/claude"
        s.inputDeviceUID = "BuiltInMicrophoneDevice"
        s.applyGlossaryFixes = false

        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == s)

        // Modes and per-app modes are written as readable JSON objects.
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["modes"] as? [String: Any])?["tidy"] != nil)
        #expect((json["perAppModes"] as? [String: String])?["com.apple.mail"] == "raw")
        #expect(json["audioRetentionDays"] is NSNull)
    }

    @Test func emptyObjectGivesDefaults() throws {
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)) == AppSettings())
    }

    @Test func nonObjectGivesDefaults() throws {
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("[1, 2]".utf8)) == AppSettings())
    }

    @Test func tolerantDecoding() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: pipelineFixture("settings-tolerant"))
        #expect(s.engine == .parakeetV3)  // unknown engine → default
        #expect(s.defaultMode == .structure)
        #expect(s.modes[.tidy] == ModeConfig(id: .tidy, claudeModel: "haiku", timeout: 25))
        #expect(s.modes[.structure] == ModeConfig(id: .structure, claudeModel: "opus", timeout: 45,
                                                  customInstructions: "Use headings."))
        #expect(s.modes[.raw] == ModeConfig.defaults[.raw])
        #expect(s.modes.count == ModeID.allCases.count)  // unknown "commitMessage" dropped
        #expect(s.perAppModes == ["com.apple.Terminal": .structure, "com.tinyspeck.slackmacgap": .tidy])
        #expect(s.hotkeyBehaviour == .holdOnly)
        #expect(s.pasteMethod == .commandV)  // wrong type → default
        #expect(!s.soundsEnabled)
        #expect(s.showLivePreview)  // missing → default
        #expect(s.audioRetentionDays == nil)  // explicit null = for ever
        #expect(s.applyGlossaryFixes)  // wrong type → default
    }

    @Test func missingModesAreFilledIn() throws {
        let json = #"{"modes": {"tidy": {"id": "tidy", "claudeModel": "opus", "timeout": 5}}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.modes[.tidy]?.claudeModel == "opus")
        #expect(s.modes[.structure] == ModeConfig.defaults[.structure])
        #expect(s.config(for: .raw) == ModeConfig.defaults[.raw])
    }

    @Test func negativeTimeoutIsIgnoredAndBlankInstructionsCleared() throws {
        let json = #"{"modes": {"tidy": {"timeout": -3, "customInstructions": "   "}}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.modes[.tidy] == ModeConfig.defaults[.tidy])
    }

    @Test func storeSavesAndLoads() throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let store = SettingsStore(url: temp.url.appendingPathComponent("nested/settings.json"))
        #expect(store.loadWithNote().note == .missing)
        #expect(store.load() == AppSettings())

        var s = AppSettings()
        s.defaultMode = .raw
        s.perAppModes["com.apple.Notes"] = .tidy
        try store.save(s)
        #expect(store.loadWithNote().note == .loaded)
        #expect(store.load() == s)

        s.soundsEnabled = false
        try store.save(s)  // overwrite
        #expect(store.load() == s)
    }

    @Test func storeMovesAnUnreadableFileAside() throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let url = temp.url.appendingPathComponent("settings.json")
        try Data("this is not json".utf8).write(to: url)
        let (settings, note) = SettingsStore(url: url).loadWithNote()
        #expect(settings == AppSettings())
        guard case .unreadable(let movedTo?) = note else {
            Issue.record("expected unreadable, got \(note)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: movedTo.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite struct ModeRouterTests {
    static let settings: AppSettings = {
        var s = AppSettings()
        s.defaultMode = .tidy
        s.perAppModes = ["com.apple.Terminal": .structure, "com.apple.mail": .raw]
        return s
    }()

    static let table: [(HotkeyTrigger, String?, ModeID)] = [
        (.defaultForApp, "com.apple.Terminal", .structure),
        (.defaultForApp, "com.apple.mail", .raw),
        (.defaultForApp, "COM.APPLE.TERMINAL", .structure),  // bundle IDs are case-insensitive
        (.defaultForApp, "com.unknown.app", .tidy),
        (.defaultForApp, nil, .tidy),
        (.mode(.raw), "com.apple.Terminal", .raw),
        (.mode(.structure), "com.apple.mail", .structure),
        (.mode(.tidy), "com.apple.Terminal", .tidy),
        (.mode(.tidy), nil, .tidy),
    ]

    @Test(arguments: 0..<table.count)
    func resolve(row: Int) {
        let (trigger, bundleID, expected) = Self.table[row]
        #expect(ModeRouter.resolve(trigger: trigger, frontmostBundleID: bundleID, settings: Self.settings) == expected)
    }

    @Test func globalDefaultIsUsedWhenNoAppMatches() {
        var s = AppSettings()
        s.defaultMode = .structure
        #expect(ModeRouter.resolve(trigger: .defaultForApp, frontmostBundleID: "com.apple.Notes", settings: s) == .structure)
    }

    @Test func whileRecording() {
        #expect(ModeRouter.actionWhileRecording(trigger: .defaultForApp, currentMode: .tidy) == .stop)
        #expect(ModeRouter.actionWhileRecording(trigger: .mode(.tidy), currentMode: .tidy) == .stop)
        #expect(ModeRouter.actionWhileRecording(trigger: .mode(.structure), currentMode: .tidy) == .switchMode(.structure))
        #expect(ModeRouter.actionWhileRecording(trigger: .mode(.raw), currentMode: .structure) == .switchMode(.raw))
    }
}
