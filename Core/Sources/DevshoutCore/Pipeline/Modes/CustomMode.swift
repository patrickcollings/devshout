import Foundation

/// The symbol on a mode's chip, from a small fixed set. The raw values are what `settings.json` stores; the app maps
/// each to an SF Symbol.
public enum ModeSymbol: String, Codable, Sendable, CaseIterable, Hashable {
    case text, sparkles, list, terminal, speechBubble, envelope, branch, pencil, document, lightBulb, checklist, bolt

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .sparkles: "Sparkles"
        case .list: "List"
        case .terminal: "Terminal"
        case .speechBubble: "Speech bubble"
        case .envelope: "Envelope"
        case .branch: "Branch"
        case .pencil: "Pencil"
        case .document: "Document"
        case .lightBulb: "Light bulb"
        case .checklist: "Checklist"
        case .bolt: "Bolt"
        }
    }
}

/// The colour of a mode's chip, from a small fixed set.
public enum ModeTint: String, Codable, Sendable, CaseIterable, Hashable {
    case grey, blue, purple, green, orange, pink, teal, red, indigo, yellow

    public var displayName: String {
        switch self {
        case .grey: "Grey"
        case .blue: "Blue"
        case .purple: "Purple"
        case .green: "Green"
        case .orange: "Orange"
        case .pink: "Pink"
        case .teal: "Teal"
        case .red: "Red"
        case .indigo: "Indigo"
        case .yellow: "Yellow"
        }
    }
}

/// A mode the user made in Settings → Modes: what Claude should do with the transcript, and how the mode looks.
/// Its hotkey is not stored here: KeyboardShortcuts keeps it in UserDefaults under a name made from `id`.
public struct CustomMode: Codable, Sendable, Hashable, Identifiable {
    /// Always a custom id (`ModeID.custom()`), never a built-in.
    public var id: ModeID
    public var name: String
    /// What to do with the transcript. They are placed inside the safety frame of `PromptBuilder`, never used as
    /// the whole prompt. While blank, the mode pastes the raw text.
    public var instructions: String
    /// A Claude Code model alias ("haiku", "sonnet", "opus") or a full model name.
    public var claudeModel: String
    /// Seconds to wait for Claude before pasting the raw text instead.
    public var timeout: TimeInterval
    public var symbol: ModeSymbol
    public var tint: ModeTint

    public static let defaultName = "Untitled mode"
    public static let defaultClaudeModel = "sonnet"
    public static let defaultTimeout: TimeInterval = 30
    public static let defaultSymbol = ModeSymbol.pencil
    public static let defaultTint = ModeTint.green
    /// Names are cut to this many characters: they have to fit a chip in the recording pill.
    public static let maximumNameLength = 40

    public init(id: ModeID = .custom(), name: String = CustomMode.defaultName, instructions: String = "",
                claudeModel: String = CustomMode.defaultClaudeModel, timeout: TimeInterval = CustomMode.defaultTimeout,
                symbol: ModeSymbol = CustomMode.defaultSymbol, tint: ModeTint = CustomMode.defaultTint) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.claudeModel = claudeModel
        self.timeout = timeout
        self.symbol = symbol
        self.tint = tint
    }

    /// The name as shown: trimmed, on one line, at most `maximumNameLength` characters, and never empty.
    public var displayName: String { Self.displayName(for: name) }

    static func displayName(for name: String) -> String {
        let oneLine = name.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.isEmpty ? defaultName : String(oneLine.prefix(maximumNameLength))
    }

    /// `name`, or `name 2`, `name 3`, … when one of `taken` already is that (compared without case).
    public static func unusedName(_ name: String, among taken: [String]) -> String {
        let base = displayName(for: name)
        let taken = Set(taken.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    public var hasInstructions: Bool {
        !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the cleaner is given for this mode.
    public var config: ModeConfig {
        ModeConfig(id: id, claudeModel: claudeModel, timeout: timeout,
                   customInstructions: hasInstructions ? instructions : nil)
    }

    // MARK: Codable (tolerant, like the rest of settings.json; only a usable `id` is required)

    enum CodingKeys: String, CodingKey { case id, name, instructions, claudeModel, timeout, symbol, tint }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(ModeID.self, forKey: .id)
        guard id.isCustom else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c,
                                                   debugDescription: "A custom mode can't use a built-in mode's id")
        }
        self.id = id
        name = c.lenient(String.self, .name) ?? Self.defaultName
        instructions = c.lenient(String.self, .instructions) ?? ""
        let model = c.lenient(String.self, .claudeModel)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        claudeModel = model.isEmpty ? Self.defaultClaudeModel : model
        if let stored = c.lenient(TimeInterval.self, .timeout), stored.isFinite, stored >= 0 {
            timeout = min(stored, ModeConfig.maximumTimeout)
        } else {
            timeout = Self.defaultTimeout
        }
        symbol = c.lenient(ModeSymbol.self, .symbol) ?? Self.defaultSymbol
        tint = c.lenient(ModeTint.self, .tint) ?? Self.defaultTint
    }
}

/// What the UI needs to show a mode, built-in or custom: one type for chips, pickers and menus.
public struct ModeDescriptor: Sendable, Hashable, Identifiable {
    public var id: ModeID
    public var name: String
    public var symbol: ModeSymbol
    public var tint: ModeTint
    /// False for a custom mode that is no longer in the settings (it was deleted after a recording used it).
    public var exists: Bool

    public init(id: ModeID, name: String, symbol: ModeSymbol, tint: ModeTint, exists: Bool = true) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.exists = exists
    }

    public var usesClaude: Bool { id.usesClaude }
    public var isBuiltIn: Bool { id.isBuiltIn }

    /// Shown for a recording whose custom mode was deleted and whose record carries no name.
    public static let deletedModeName = "Deleted mode"

    public static let raw = ModeDescriptor(id: .raw, name: "Raw", symbol: .text, tint: .grey)
    public static let tidy = ModeDescriptor(id: .tidy, name: "Tidy", symbol: .sparkles, tint: .blue)
    public static let structure = ModeDescriptor(id: .structure, name: "Structure", symbol: .list, tint: .purple)
    public static let builtIns: [ModeDescriptor] = [.raw, .tidy, .structure]

    public init(_ mode: CustomMode) {
        self.init(id: mode.id, name: mode.displayName, symbol: mode.symbol, tint: mode.tint)
    }

    /// A mode that isn't in the list any more: the name stored with the recording, else "Deleted mode".
    public static func deleted(_ id: ModeID, storedName: String? = nil) -> ModeDescriptor {
        let stored = storedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ModeDescriptor(id: id, name: stored.isEmpty ? deletedModeName : CustomMode.displayName(for: stored),
                              symbol: .document, tint: .grey, exists: false)
    }
}

extension Array where Element == ModeDescriptor {
    /// The descriptor for `id`. A mode that isn't in the list is shown under `storedName` (the name its recording
    /// kept), else as "Deleted mode".
    public func descriptor(for id: ModeID, storedName: String? = nil) -> ModeDescriptor {
        first { $0.id == id }
            ?? ModeDescriptor.builtIns.first { $0.id == id }
            ?? .deleted(id, storedName: storedName)
    }
}

// MARK: - Hotkeys

extension ModeID {
    /// The name under which this mode's own hotkey is registered and stored (KeyboardShortcuts keeps it in
    /// UserDefaults as `KeyboardShortcuts_<name>`). The built-ins keep the names they have always had, so hotkeys
    /// set before custom modes existed still work; a custom mode's name is made from its id, which holds only
    /// letters, digits and hyphens (KeyboardShortcuts forbids a dot in a name).
    public var hotkeyName: String {
        switch self {
        case .raw: "dictateRaw"
        case .tidy: "dictateTidy"
        case .structure: "dictateStructure"
        default: "dictateMode_" + rawValue
        }
    }
}

// MARK: - Settings

extension AppSettings {
    /// Every mode that can be chosen: the built-ins, then the custom modes in the user's order.
    public var modeDescriptors: [ModeDescriptor] {
        ModeDescriptor.builtIns + customModes.map(ModeDescriptor.init)
    }

    public func customMode(_ id: ModeID) -> CustomMode? {
        customModes.first { $0.id == id }
    }

    /// Whether `id` is a built-in or a custom mode that is still in the settings.
    public func hasMode(_ id: ModeID) -> Bool {
        id.isBuiltIn || customMode(id) != nil
    }

    public func descriptor(for id: ModeID, storedName: String? = nil) -> ModeDescriptor {
        modeDescriptors.descriptor(for: id, storedName: storedName)
    }

    /// The name to keep in a recording so it can still be shown after the mode is deleted: a custom mode's name,
    /// nil for a built-in (its name never changes).
    public func storedName(for id: ModeID) -> String? {
        customMode(id)?.displayName
    }

    /// Removes a custom mode and everything that pointed at it: the default mode goes back to Tidy and per-app
    /// rules for it are dropped. Does nothing for a built-in.
    public mutating func removeCustomMode(_ id: ModeID) {
        guard id.isCustom else { return }
        customModes.removeAll { $0.id == id }
        dropReferencesToMissingModes()
    }

    /// Makes `defaultMode` and `perAppModes` name only modes that exist. Call it after replacing `customModes`.
    public mutating func dropReferencesToMissingModes() {
        if !hasMode(defaultMode) { defaultMode = AppSettings.fallbackMode }
        perAppModes = perAppModes.filter { hasMode($0.value) }
    }

    /// What a missing mode falls back to.
    public static let fallbackMode = ModeID.tidy

    /// `name`, or `name 2`, `name 3`, … when a mode (built-in or custom) already has it.
    public func unusedModeName(_ name: String) -> String {
        CustomMode.unusedName(name, among: modeDescriptors.map(\.name))
    }
}

// MARK: - Templates

/// A ready-made custom mode offered by "Add" in Settings → Modes. Adding one copies it; the copy is then the user's.
public struct CustomModeTemplate: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var instructions: String
    public var claudeModel: String
    public var timeout: TimeInterval
    public var symbol: ModeSymbol
    public var tint: ModeTint

    /// A new mode from this template, with its own id.
    public func makeMode(id: ModeID = .custom(), name: String? = nil) -> CustomMode {
        CustomMode(id: id, name: name ?? self.name, instructions: instructions, claudeModel: claudeModel,
                   timeout: timeout, symbol: symbol, tint: tint)
    }

    public static let all: [CustomModeTemplate] = [.codingAgentPrompt, .slackMessage, .commitMessage, .email]

    public static let codingAgentPrompt = CustomModeTemplate(
        id: "coding-agent-prompt", name: "Prompt for a coding agent",
        instructions: """
            The speaker is thinking aloud about a task for an AI coding agent. Write the prompt they would have \
            typed if they had planned it first.

            Start with the goal in one or two sentences. Then give the context the agent needs, the requirements \
            as a numbered list, the constraints and anything to leave alone, how to check the work, and any \
            questions the speaker left open. Leave out a part the speaker said nothing about.

            Keep every requirement, file path, name, number, ticket ID and example the speaker gave, and add none \
            of your own. When the speaker changes their mind, keep only the final version. Address the agent \
            directly ("Add…", "Do not change…"). Use Markdown with short headings.
            """,
        claudeModel: "sonnet", timeout: 45, symbol: .terminal, tint: .green)

    public static let slackMessage = CustomModeTemplate(
        id: "slack-message", name: "Slack message",
        instructions: """
            Write what the speaker said as a Slack message from them, the way they would type it to a colleague: \
            short, conversational and in the first person. Lead with the point or the question. No greeting line, \
            no sign-off and no subject.

            Keep every name, number, date, link and ticket ID. Use short paragraphs, and a bulleted list only when \
            the speaker lists several separate items. Put code, commands and file names in `backticks`. No \
            headings, and no emoji unless the speaker asks for one. Do not make the message more formal or more \
            enthusiastic than the speaker was.
            """,
        claudeModel: "haiku", timeout: 20, symbol: .speechBubble, tint: .pink)

    public static let commitMessage = CustomModeTemplate(
        id: "commit-message", name: "Commit message",
        instructions: """
            Write a Git commit message for the change the speaker describes.

            First a subject line of at most 72 characters, in the imperative mood ("Fix…", "Add…"), with no full \
            stop at the end. Then a blank line and a body in plain prose, wrapped at about 72 characters, that \
            says what changed and why. Leave the body out when the subject line says everything.

            Give ticket IDs, file names and identifiers exactly as the speaker said them. Describe only the \
            changes the speaker mentions. No Markdown headings, no bulleted list unless the speaker lists separate \
            changes, and no trailers such as Co-authored-by unless the speaker dictates one.
            """,
        claudeModel: "haiku", timeout: 20, symbol: .branch, tint: .orange)

    public static let email = CustomModeTemplate(
        id: "email", name: "Email",
        instructions: """
            Write what the speaker said as an email from them.

            If the speaker gives a subject, put it on the first line as "Subject: …" followed by a blank line; \
            otherwise write no subject line. Open with a greeting to the person the speaker names ("Hi Sam,"), or \
            "Hi," when they name no one. Put the main point or request in the first paragraph, then the detail in \
            short paragraphs, then anything the reader needs to do and by when. End with a short sign-off on its \
            own line ("Thanks," or "Best wishes,") and no name after it, unless the speaker says how to sign off.

            Keep every name, date, time, number and commitment the speaker gave, and add none. Polite and direct, \
            in the speaker's own register, with no stock phrases such as "I hope this email finds you well". \
            Plain text, no Markdown.
            """,
        claudeModel: "sonnet", timeout: 30, symbol: .envelope, tint: .teal)
}
