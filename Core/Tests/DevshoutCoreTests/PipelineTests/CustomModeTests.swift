import Foundation
import Testing
@testable import DevshoutCore

@Suite struct ModeIDTests {
    @Test func builtInsKeepTheirNamesOnDisk() throws {
        #expect(ModeID.builtIns == [.raw, .tidy, .structure])
        #expect(ModeID.builtIns.map(\.rawValue) == ["raw", "tidy", "structure"])
        #expect(ModeID.builtIns.map(\.displayName) == ["Raw", "Tidy", "Structure"])
        #expect(ModeID(rawValue: "tidy") == .tidy)
        #expect(ModeID.builtIns.allSatisfy { $0.isBuiltIn })
        // Written as the bare string, exactly as the enum was.
        #expect(String(decoding: try JSONEncoder().encode([ModeID.structure]), as: UTF8.self) == #"["structure"]"#)
        #expect(try JSONDecoder().decode([ModeID].self, from: Data(#"["raw"]"#.utf8)) == [.raw])
    }

    @Test func customIDs() throws {
        let uuid = try #require(UUID(uuidString: "11111111-AAAA-4BBB-8CCC-000000000001"))
        let id = ModeID.custom(uuid)
        #expect(id.rawValue == "custom-11111111-aaaa-4bbb-8ccc-000000000001")
        #expect(id.isCustom)
        #expect(!id.isBuiltIn)
        #expect(id.usesClaude)
        #expect(id.builtInName == nil)
        #expect(ModeID(rawValue: id.rawValue) == id)
        #expect(ModeID.custom() != ModeID.custom())
        let data = try JSONEncoder().encode([id])
        #expect(try JSONDecoder().decode([ModeID].self, from: data) == [id])
    }

    @Test(arguments: ["", "shout", "Tidy", "custom-", "custom", "custom-a.b", "custom-a b", "custom-a/b",
                      "custom-é", "custom-" + String(repeating: "a", count: 65)])
    func stringsThatAreNotModes(raw: String) {
        #expect(ModeID(rawValue: raw) == nil)
        // So a tolerant decoder falls back to its default for them.
        let json = Data("[\"\(raw)\"]".utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode([ModeID].self, from: json) }
    }
}

@Suite struct CustomModeTests {
    static let slackID = ModeID(rawValue: "custom-11111111-aaaa-4bbb-8ccc-000000000001")!
    static let secondID = ModeID(rawValue: "custom-22222222-aaaa-4bbb-8ccc-000000000002")!
    static let slack = CustomMode(id: slackID, name: "Slack message",
                                  instructions: "Write what the speaker said as a Slack message.",
                                  claudeModel: "haiku", timeout: 20, symbol: .speechBubble, tint: .pink)

    // MARK: settings.json

    @Test func aSettingsFileFromBeforeCustomModesLoadsUnchanged() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: pipelineFixture("settings-before-custom-modes"))
        #expect(s.customModes.isEmpty)
        #expect(s.defaultMode == .tidy)
        #expect(s.modes[.tidy] == ModeConfig.defaults[.tidy])
        #expect(s.modes[.raw] == ModeConfig.defaults[.raw])
        #expect(s.modes[.structure] == ModeConfig(id: .structure, claudeModel: "opus", timeout: 60,
                                                  customInstructions: "Write a brief for the agent, in Markdown."))
        #expect(s.perAppModes == ["com.apple.Terminal": .structure, "com.apple.mail": .raw,
                                  "com.tinyspeck.slackmacgap": .tidy])
        #expect(!s.soundsEnabled)
        #expect(s.claudePathOverride == "/Users/patrick/.local/bin/claude")
        #expect(s.modeDescriptors == ModeDescriptor.builtIns)

        // Saved again and reloaded, it is the same settings, and the built-ins keep their keys.
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == s)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set((json["modes"] as? [String: Any] ?? [:]).keys) == ["raw", "tidy", "structure"])
        #expect((json["customModes"] as? [Any])?.isEmpty == true)
    }

    @Test func customModesRoundTrip() throws {
        var s = AppSettings()
        let email = CustomModeTemplate.email.makeMode(id: Self.secondID)
        s.customModes = [Self.slack, email]
        s.defaultMode = Self.slackID
        s.perAppModes = ["com.apple.mail": Self.secondID, "com.apple.Terminal": .structure]

        let data = try JSONEncoder().encode(s)
        let loaded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(loaded == s)
        #expect(loaded.customModes.map(\.id) == [Self.slackID, Self.secondID])  // the user's order
        #expect(loaded.customMode(Self.secondID)?.instructions == CustomModeTemplate.email.instructions)

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["defaultMode"] as? String == Self.slackID.rawValue)
        #expect((json["perAppModes"] as? [String: String])?["com.apple.mail"] == Self.secondID.rawValue)
        let first = try #require((json["customModes"] as? [[String: Any]])?.first)
        #expect(first["id"] as? String == Self.slackID.rawValue)
        #expect(first["name"] as? String == "Slack message")
        #expect(first["symbol"] as? String == "speechBubble")
        #expect(first["tint"] as? String == "pink")
        // Custom modes are not mixed into the built-ins' table.
        #expect(Set((json["modes"] as? [String: Any] ?? [:]).keys) == ["raw", "tidy", "structure"])
    }

    @Test func damagedCustomModesAreSkippedAndTheRestKept() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: pipelineFixture("settings-custom-modes"))
        #expect(s.customModes.map(\.id) == [Self.slackID, Self.secondID])
        #expect(s.customModes.first == Self.slack)

        // Only an id is needed; everything else takes a default.
        let sparse = try #require(s.customMode(Self.secondID))
        #expect(sparse.name == "  ")
        #expect(sparse.displayName == CustomMode.defaultName)
        #expect(sparse.instructions.isEmpty)
        #expect(sparse.claudeModel == CustomMode.defaultClaudeModel)
        #expect(sparse.timeout == ModeConfig.maximumTimeout)  // 1e30 is clamped, as for the built-ins
        #expect(sparse.symbol == CustomMode.defaultSymbol)
        #expect(sparse.tint == CustomMode.defaultTint)

        // The entry under "modes" keyed by a custom id is ignored: a custom mode's model is its own.
        #expect(s.modes.count == ModeID.builtIns.count)
        #expect(s.config(for: Self.slackID).claudeModel == "haiku")

        #expect(s.defaultMode == Self.slackID)
        // The rule for a custom mode that isn't in the file is dropped.
        #expect(s.perAppModes == ["com.tinyspeck.slackmacgap": Self.slackID, "com.apple.Terminal": .structure])
    }

    @Test func aDefaultModeThatIsMissingFallsBackToTidy() throws {
        let json = #"{"defaultMode": "custom-99999999-aaaa-4bbb-8ccc-000000000009", "customModes": "oops"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.defaultMode == .tidy)
        #expect(s.customModes.isEmpty)
    }

    // MARK: Looking modes up

    @Test func configForACustomMode() {
        var s = AppSettings()
        s.customModes = [Self.slack, CustomMode(id: Self.secondID, name: "Blank", instructions: " \n", timeout: .infinity)]
        #expect(s.config(for: Self.slackID) == ModeConfig(id: Self.slackID, claudeModel: "haiku", timeout: 20,
                                                          customInstructions: Self.slack.instructions))
        // Blank instructions are no instructions; the timeout is bounded as everywhere else.
        let blank = s.config(for: Self.secondID)
        #expect(blank.customInstructions == nil)
        #expect(blank.timeout == ModeConfig.maximumTimeout)
        // A mode that was deleted has nothing to send.
        let gone = s.config(for: .custom())
        #expect(gone.customInstructions == nil)
        #expect(gone.claudeModel.isEmpty)
        // The built-ins are untouched.
        #expect(s.config(for: .tidy) == ModeConfig.defaults[.tidy])
    }

    @Test func descriptors() {
        var s = AppSettings()
        s.customModes = [Self.slack]
        #expect(s.modeDescriptors.map(\.id) == [.raw, .tidy, .structure, Self.slackID])
        #expect(s.modeDescriptors.map(\.name) == ["Raw", "Tidy", "Structure", "Slack message"])
        #expect(s.modeDescriptors.filter(\.usesClaude).map(\.id) == [.tidy, .structure, Self.slackID])

        let slack = s.descriptor(for: Self.slackID, storedName: "An older name")
        #expect(slack == ModeDescriptor(id: Self.slackID, name: "Slack message", symbol: .speechBubble, tint: .pink))
        #expect(slack.exists)
        #expect(!slack.isBuiltIn)
        #expect(s.descriptor(for: .structure) == .structure)
        #expect(s.storedName(for: Self.slackID) == "Slack message")
        #expect(s.storedName(for: .tidy) == nil)
        #expect(s.hasMode(Self.slackID))
        #expect(s.hasMode(.raw))
        #expect(!s.hasMode(Self.secondID))
    }

    @Test func aDeletedModeIsShownByItsStoredName() {
        let s = AppSettings()
        let named = s.descriptor(for: Self.slackID, storedName: "Slack message")
        #expect(named.name == "Slack message")
        #expect(!named.exists)
        #expect(named.id == Self.slackID)
        #expect(s.descriptor(for: Self.slackID).name == "Deleted mode")
        #expect(s.descriptor(for: Self.slackID, storedName: "  ").name == "Deleted mode")
        // Without the settings to hand, a list of descriptors answers the same way.
        #expect([ModeDescriptor]().descriptor(for: .tidy) == .tidy)
        #expect([ModeDescriptor]().descriptor(for: Self.slackID, storedName: "Email").name == "Email")
    }

    @Test func namesAreTidiedForDisplay() {
        #expect(CustomMode(name: "  Email \n").displayName == "Email")
        #expect(CustomMode(name: "").displayName == "Untitled mode")
        #expect(CustomMode(name: "Two\nlines").displayName == "Two lines")
        #expect(CustomMode(name: String(repeating: "x", count: 90)).displayName.count == CustomMode.maximumNameLength)
    }

    @Test func removingAModeRemovesWhatPointedAtIt() {
        var s = AppSettings()
        s.customModes = [Self.slack, CustomMode(id: Self.secondID, name: "Email")]
        s.defaultMode = Self.slackID
        s.perAppModes = ["com.tinyspeck.slackmacgap": Self.slackID, "com.apple.mail": Self.secondID,
                         "com.apple.Terminal": .structure]
        s.removeCustomMode(Self.slackID)
        #expect(s.customModes.map(\.id) == [Self.secondID])
        #expect(s.defaultMode == .tidy)
        #expect(s.perAppModes == ["com.apple.mail": Self.secondID, "com.apple.Terminal": .structure])

        // A built-in can't be removed.
        let before = s
        s.removeCustomMode(.structure)
        #expect(s == before)
    }

    @Test func unusedNames() {
        var s = AppSettings()
        #expect(s.unusedModeName("Email") == "Email")
        #expect(s.unusedModeName("tidy") == "tidy 2")  // a built-in's name is taken too
        s.customModes = [CustomMode(name: "Email"), CustomMode(name: "email 2")]
        #expect(s.unusedModeName("Email") == "Email 3")
        #expect(s.unusedModeName("  ") == "Untitled mode")
    }

    // MARK: Templates

    @Test func templates() {
        #expect(CustomModeTemplate.all.map(\.name) == ["Prompt for a coding agent", "Slack message", "Commit message",
                                                       "Email"])
        #expect(Set(CustomModeTemplate.all.map(\.id)).count == 4)
        for template in CustomModeTemplate.all {
            let mode = template.makeMode()
            #expect(mode.id.isCustom)
            #expect(mode.name == template.name)
            #expect(mode.hasInstructions)
            #expect(["haiku", "sonnet"].contains(mode.claudeModel))
            #expect(mode.timeout >= 20 && mode.timeout <= 60)
            // British English, and nothing that reads as a tag inside the prompt's own blocks.
            for american in ["summarize", "organize", "color", "behavior", "period at the end"] {
                #expect(!mode.instructions.lowercased().contains(american), "\(template.name): \(american)")
            }
            #expect(!mode.instructions.contains("<"))
        }
        #expect(CustomModeTemplate.email.makeMode().id != CustomModeTemplate.email.makeMode().id)
        #expect(CustomModeTemplate.email.makeMode(name: "Email 2").name == "Email 2")
    }

    // MARK: Routing

    @Test func routing() {
        var s = AppSettings()
        s.customModes = [Self.slack]
        s.perAppModes = ["com.tinyspeck.slackmacgap": Self.slackID, "com.apple.mail": Self.secondID]
        func resolve(_ trigger: HotkeyTrigger, _ bundleID: String?) -> ModeID {
            ModeRouter.resolve(trigger: trigger, frontmostBundleID: bundleID, settings: s)
        }
        #expect(resolve(.mode(Self.slackID), "com.apple.Terminal") == Self.slackID)
        #expect(resolve(.defaultForApp, "com.tinyspeck.slackmacgap") == Self.slackID)
        #expect(resolve(.defaultForApp, "COM.TINYSPECK.SLACKMACGAP") == Self.slackID)
        // A rule or a hotkey for a mode that has gone falls back to the default mode.
        #expect(resolve(.defaultForApp, "com.apple.mail") == .tidy)
        #expect(resolve(.mode(Self.secondID), nil) == .tidy)
        s.defaultMode = Self.slackID
        #expect(resolve(.defaultForApp, nil) == Self.slackID)
        #expect(resolve(.mode(Self.secondID), nil) == Self.slackID)
        // And if the default mode itself has gone, to Tidy.
        s.defaultMode = Self.secondID
        #expect(resolve(.defaultForApp, nil) == .tidy)
        #expect(resolve(.defaultForApp, "com.apple.mail") == .tidy)
    }

    @Test func switchingWhileRecording() {
        #expect(ModeRouter.actionWhileRecording(trigger: .mode(Self.slackID), currentMode: .tidy)
                == .switchMode(Self.slackID))
        #expect(ModeRouter.actionWhileRecording(trigger: .mode(Self.slackID), currentMode: Self.slackID) == .stop)
        #expect(ModeRouter.actionWhileRecording(trigger: .mode(.tidy), currentMode: Self.slackID) == .switchMode(.tidy))
    }

    // MARK: record.json

    @Test func aRecordFromBeforeCustomModesLoads() throws {
        let r = try HistoryStore.decoder.decode(Recording.self, from: pipelineFixture("record-before-custom-modes"))
        #expect(r.mode == .tidy)
        #expect(r.modeName == nil)
        #expect(r.status == .completed)
        #expect(r.versions.map(\.mode) == [.tidy, .structure])
        #expect(r.versions.allSatisfy { $0.modeName == nil })
        #expect(r.versions.last?.warnings == ["may have dropped: 42"])
        #expect(r.deliveredText == "Can you check the CORSIA flag?")
        #expect(r.timings.total == 1.9)
        // Written back and read again, nothing has changed.
        let data = try HistoryStore.encoder.encode(r)
        #expect(try HistoryStore.decoder.decode(Recording.self, from: data) == r)
        #expect(!String(decoding: data, as: UTF8.self).contains("modeName"))
    }

    @Test func aRecordMadeInACustomModeKeepsItsIDAndName() throws {
        let r = try HistoryStore.decoder.decode(Recording.self, from: pipelineFixture("record-custom-mode"))
        #expect(r.mode == Self.slackID)
        #expect(r.modeName == "Slack message")
        #expect(r.versions.count == 3)
        #expect(r.versions[0].mode == Self.slackID)
        #expect(r.versions[0].modeName == "Slack message")
        // A version from a mode whose name was never stored still loads, under its id.
        #expect(r.versions[1].mode.rawValue == "custom-33333333-aaaa-4bbb-8ccc-000000000003")
        #expect(r.versions[1].modeName == nil)
        // A mode string that was never valid falls back to Tidy, as it always did.
        #expect(r.versions[2].mode == .tidy)

        let data = try HistoryStore.encoder.encode(r)
        #expect(try HistoryStore.decoder.decode(Recording.self, from: data) == r)

        // With the mode deleted, History can still say what it was.
        let settings = AppSettings()
        #expect(settings.descriptor(for: r.mode, storedName: r.modeName).name == "Slack message")
        #expect(settings.descriptor(for: r.versions[1].mode, storedName: r.versions[1].modeName).name == "Deleted mode")
    }

    // MARK: The session

    @Test func aDictationInACustomModeIsCleanedWithItsConfigAndRemembersItsName() async throws {
        var settings = AppSettings()
        settings.customModes = [Self.slack]
        let h = try SessionHarness(settings: settings)
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: Self.slackID, targetApp: nil)
        _ = await h.session.stop()

        #expect(h.cleaner.calls.get().map(\.mode) == [settings.config(for: Self.slackID)])
        #expect(h.deliverer.delivered.get() == ["Cleaned: Part 0 Part 1 Part 2"])
        let saved = try #require(try h.history.load(id))
        #expect(saved.mode == Self.slackID)
        #expect(saved.modeName == "Slack message")
        #expect(saved.versions.first?.mode == Self.slackID)
        #expect(saved.versions.first?.modeName == "Slack message")
    }

    @Test func switchingBetweenBuiltInAndCustomModesKeepsTheNameInStep() async throws {
        var settings = AppSettings()
        settings.customModes = [Self.slack]
        let h = try SessionHarness(settings: settings)
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: .tidy, targetApp: nil)
        #expect(await h.session.setMode(Self.slackID))
        #expect(await h.session.setMode(.structure))
        #expect(await h.session.setMode(Self.slackID))
        await h.session.cancel()
        // Cancelled recordings carry the name too.
        let cancelled = try #require(try h.history.load(id))
        #expect(cancelled.mode == Self.slackID)
        #expect(cancelled.modeName == "Slack message")

        let second = try SessionHarness(settings: settings)
        defer { second.temp.remove() }
        let secondID = try await second.session.start(mode: Self.slackID, targetApp: nil)
        #expect(await second.session.setMode(.structure))
        _ = await second.session.stop()
        let saved = try #require(try second.history.load(secondID))
        #expect(saved.mode == .structure)
        #expect(saved.modeName == nil)
        #expect(saved.versions.first?.modeName == nil)
    }

    @Test func aCustomModeWhoseCleanUpFailsPastesTheRawText() async throws {
        var settings = AppSettings()
        settings.customModes = [Self.slack]
        let h = try SessionHarness(cleaner: FakeCleaner { _, mode, _ in
            CleanResult(text: "  \n", model: mode.claudeModel, elapsed: 0.1)
        }, settings: settings)
        defer { h.temp.remove() }
        let id = try await h.session.start(mode: Self.slackID, targetApp: nil)
        _ = await h.session.stop()
        #expect(h.deliverer.delivered.get() == ["Part 0 Part 1 Part 2"])
        let saved = try #require(try h.history.load(id))
        #expect(saved.versions.isEmpty)
        #expect(saved.fallbackReason?.contains("empty output") == true)
    }
}
