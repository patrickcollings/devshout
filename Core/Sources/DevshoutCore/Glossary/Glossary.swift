import Foundation

// The glossary model (PLAN §6.1). One `glossary.md` that Patrick edits in the app (PLAN §0 item 4).
// The model keeps every line of a hand-written file: lines that are not entries are kept as notes,
// so writing a parsed glossary back out loses nothing that matters and Claude still sees them.

/// What a `##` section holds. Terms, People and Patterns contain entries; Style and anything else is free text.
public enum GlossarySectionKind: String, Codable, Sendable, Hashable, CaseIterable {
    case terms, people, patterns, style
    /// Text before the first `##` heading, or a section with a heading devshout doesn't know.
    case other

    /// Whether lines in this section are parsed as entries.
    public var holdsEntries: Bool {
        switch self {
        case .terms, .people, .patterns: true
        case .style, .other: false
        }
    }

    /// The kind for a `##` heading's text ("Terms", "people:", "Ticket patterns" …). Case-insensitive.
    public static func forHeading(_ heading: String) -> GlossarySectionKind {
        var name = heading.trimmingCharacters(in: .whitespaces)
        while let last = name.last, last == "#" || last == ":" || last == " " { name.removeLast() }
        switch name.lowercased() {
        case "terms", "term", "vocabulary", "jargon", "words", "glossary": return .terms
        case "people", "person", "names", "team", "team members": return .people
        case "patterns", "pattern", "ids", "ticket ids", "ticket patterns": return .patterns
        case "style", "style notes", "style guide", "house style": return .style
        default: return .other
        }
    }
}

/// One glossary entry: `- **Term** — description`, with optional `heard:` mishearings.
public struct GlossaryEntry: Codable, Sendable, Hashable {
    /// The correct spelling. In Patterns, `{n}` stands for a number (`AB-{n}`).
    public var term: String
    public var description: String?
    /// Known mishearings, in the order written. In Patterns they may contain `{n}` too.
    public var heard: [String]
    /// `!` before the term: goes to the top of the Whisper vocabulary list.
    public var pinned: Bool
    /// Other sub-bullets and continuation lines under the entry, without their bullets.
    public var notes: [String]

    public init(term: String, description: String? = nil, heard: [String] = [], pinned: Bool = false, notes: [String] = []) {
        self.term = term
        self.description = description
        self.heard = heard
        self.pinned = pinned
        self.notes = notes
    }

    /// Whether the term contains a `{n}` number placeholder.
    public var isPattern: Bool { term.contains(GlossaryEntry.numberPlaceholder) }

    public static let numberPlaceholder = "{n}"
}

/// A line kept as written: free text, an HTML comment, a blank line or a line the parser didn't recognise.
public struct GlossaryNote: Codable, Sendable, Hashable {
    /// The line exactly as written (without its line break).
    public var raw: String
    /// The line with HTML comments removed and trailing spaces trimmed: what Claude sees. Empty for comments and blank lines.
    public var text: String

    public init(raw: String, text: String) {
        self.raw = raw
        self.text = text
    }

    /// A note whose raw text and visible text are the same line.
    public init(_ line: String) {
        self.raw = line
        self.text = GlossaryNote.trimTrailing(line)
    }

    static func trimTrailing(_ s: String) -> String {
        var s = Substring(s)
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return String(s)
    }
}

public enum GlossaryItem: Codable, Sendable, Hashable {
    case entry(GlossaryEntry)
    case note(GlossaryNote)

    public var entry: GlossaryEntry? {
        if case .entry(let e) = self { return e }
        return nil
    }

    public var note: GlossaryNote? {
        if case .note(let n) = self { return n }
        return nil
    }
}

public struct GlossarySection: Codable, Sendable, Hashable {
    /// The heading text after `## `, as written. `nil` for the text before the first heading.
    public var heading: String?
    public var kind: GlossarySectionKind
    public var items: [GlossaryItem]

    public init(heading: String?, kind: GlossarySectionKind? = nil, items: [GlossaryItem] = []) {
        self.heading = heading
        self.kind = kind ?? heading.map(GlossarySectionKind.forHeading) ?? .other
        self.items = items
    }

    public var entries: [GlossaryEntry] { items.compactMap(\.entry) }
    public var notes: [GlossaryNote] { items.compactMap(\.note) }
}

/// A parsed `glossary.md`.
public struct Glossary: Codable, Sendable, Hashable {
    /// Sections in file order. The first has `heading == nil` when the file has text before its first `##`.
    public var sections: [GlossarySection]

    public init(sections: [GlossarySection] = []) {
        self.sections = sections
    }

    /// Parses Markdown. Never fails: anything unrecognised is kept as a note.
    public init(markdown: String) {
        self = GlossaryParser.parse(markdown)
    }

    public static let empty = Glossary()

    /// The `# Title` line, if any.
    public var title: String? {
        for section in sections where section.heading == nil {
            for note in section.notes {
                let t = note.text.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("# ") { return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }

    /// Every entry in a section of the given kind, in file order.
    public func entries(in kind: GlossarySectionKind) -> [GlossaryEntry] {
        sections.filter { $0.kind == kind }.flatMap(\.entries)
    }

    /// Every entry in file order, with the kind of section it is in.
    public var allEntries: [(kind: GlossarySectionKind, entry: GlossaryEntry)] {
        sections.flatMap { s in s.entries.map { (s.kind, $0) } }
    }

    public var terms: [GlossaryEntry] { entries(in: .terms) }
    public var people: [GlossaryEntry] { entries(in: .people) }

    /// Entries in Patterns sections that contain `{n}`, plus any `{n}` entry elsewhere.
    public var patterns: [GlossaryEntry] { allEntries.map(\.entry).filter(\.isPattern) }

    /// The free text of every Style section (comments and leading/trailing blank lines removed).
    public var styleText: String {
        GlossaryRenderer.freeText(sections.filter { $0.kind == .style }.flatMap(\.notes))
    }

    /// Whether there is nothing Claude, Whisper or the TextFixer would use.
    public var isEffectivelyEmpty: Bool {
        allEntries.isEmpty && sections.allSatisfy { s in s.notes.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty || ($0.text.hasPrefix("# ") && s.heading == nil) } }
    }

    /// "12 terms, 3 people, 1 pattern" for Settings.
    public var countsSummary: String {
        func n(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }
        let plainTerms = terms.filter { !$0.isPattern }.count
        return [n(plainTerms, "term", "terms"), n(people.count, "person", "people"), n(patterns.count, "pattern", "patterns")]
            .joined(separator: ", ")
    }
}
