import Foundation

/// Parses `glossary.md` (PLAN §6.1). Never fails: a hand-written file always gives a glossary, and every line
/// that isn't an entry is kept as a note (so Claude still sees it and writing the file back keeps it).
///
/// The rules:
/// - `## Heading` starts a section. Terms, People and Patterns hold entries; Style and other headings are free text.
/// - `- **Term** — description`. The separator after the bold term may be `—`, `–`, `-` or `:` (or nothing).
///   A plain `- Term — description` without bold works too (there, `-` needs spaces around it).
/// - Mishearings as a sub-bullet (`  - heard: a, b`) or inline (`— heard: a, b`, or `(heard: a, b)` anywhere in
///   the line), comma- or semicolon-separated.
/// - A leading `!` (`- !**CORSIA**`, `- **!CORSIA**` or `- ! CORSIA`) pins the entry.
/// - Other indented lines under an entry are kept as its notes. HTML comments (`<!-- … -->`, across lines too)
///   are ignored, so commented-out entries do nothing.
public enum GlossaryParser {
    public static func parse(_ markdown: String) -> Glossary {
        parseWithLocations(markdown).glossary
    }

    // MARK: - Internals (also used by GlossaryEditor)

    /// Where an entry sits in the normalised lines of the file.
    struct EntryLocation: Sendable, Hashable {
        var section: Int
        var item: Int
        /// Index of the entry's own line.
        var line: Int
        /// Index of the last line that belongs to the entry (its last sub-bullet or continuation line).
        var lastLine: Int
        /// The first `heard:` sub-bullet line, if any.
        var heardLine: Int?
        /// Whether the entry's own line has an inline `heard:`.
        var inlineHeard: Bool
    }

    struct Parsed {
        var glossary: Glossary
        var lines: [String]
        var entries: [EntryLocation]
        /// For each section, the index of its heading line (nil for the text before the first heading).
        var headingLines: [Int?]
    }

    /// Splits text into lines: drops a UTF-8 BOM, treats CRLF and CR as LF, and drops the empty line after a final newline.
    static func lines(of text: String) -> [String] {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // "\r\n" is a single Character in Swift, so split on both forms explicitly.
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func parseWithLocations(_ markdown: String) -> Parsed {
        let lines = lines(of: markdown)
        var sections: [GlossarySection] = []
        var headingLines: [Int?] = []
        var locations: [EntryLocation] = []
        var inComment = false
        /// Index into `locations` of the entry that sub-lines attach to.
        var current: Int?

        func ensureSection() {
            if sections.isEmpty {
                sections.append(GlossarySection(heading: nil, kind: .other))
                headingLines.append(nil)
            }
        }
        func appendNote(_ raw: String, _ visible: String) {
            ensureSection()
            sections[sections.count - 1].items.append(.note(GlossaryNote(raw: raw, text: GlossaryNote.trimTrailing(visible))))
        }

        for (index, raw) in lines.enumerated() {
            let visible = stripComments(raw, inComment: &inComment)
            let trimmed = visible.trimmingCharacters(in: .whitespaces)

            if let heading = sectionHeading(visible) {
                sections.append(GlossarySection(heading: heading))
                headingLines.append(index)
                current = nil
                continue
            }
            ensureSection()
            let s = sections.count - 1
            guard sections[s].kind.holdsEntries else {
                appendNote(raw, visible)
                continue
            }
            if trimmed.isEmpty {
                // Blank lines and whole-line comments don't end an entry.
                appendNote(raw, visible)
                continue
            }
            if isIndented(visible), let c = current {
                let content = stripBullet(trimmed)
                var entry = sections[s].items[locations[c].item].entry!
                if let heard = heardList(atStartOf: content) {
                    entry.heard = mergeHeard(entry.heard, heard)
                    if locations[c].heardLine == nil { locations[c].heardLine = index }
                } else {
                    entry.notes.append(content)
                }
                sections[s].items[locations[c].item] = .entry(entry)
                locations[c].lastLine = index
                continue
            }
            if !isIndented(visible), let content = topLevelBulletContent(visible),
               let (entry, inline) = parseEntry(content) {
                sections[s].items.append(.entry(entry))
                locations.append(EntryLocation(section: s, item: sections[s].items.count - 1, line: index,
                                               lastLine: index, heardLine: nil, inlineHeard: inline))
                current = locations.count - 1
                continue
            }
            appendNote(raw, visible)
            current = nil
        }
        return Parsed(glossary: Glossary(sections: sections), lines: lines, entries: locations, headingLines: headingLines)
    }

    /// Removes `<!-- … -->` from a line, carrying an unclosed comment over to the next line.
    static func stripComments(_ line: String, inComment: inout Bool) -> String {
        var out = ""
        var i = line.startIndex
        while i < line.endIndex {
            if inComment {
                if let r = line.range(of: "-->", range: i..<line.endIndex) {
                    i = r.upperBound
                    inComment = false
                } else {
                    i = line.endIndex
                }
            } else if let r = line.range(of: "<!--", range: i..<line.endIndex) {
                out += line[i..<r.lowerBound]
                i = r.upperBound
                inComment = true
            } else {
                out += line[i...]
                i = line.endIndex
            }
        }
        return out
    }

    /// The text of a `## Heading` line (exactly two hashes, up to three spaces of indent).
    static func sectionHeading(_ line: String) -> String? {
        let leading = line.prefix(while: { $0 == " " })
        guard leading.count <= 3 else { return nil }
        let rest = line.dropFirst(leading.count)
        guard rest.hasPrefix("##"), !rest.hasPrefix("###") else { return nil }
        let after = rest.dropFirst(2)
        guard after.isEmpty || after.first!.isWhitespace else { return nil }
        var heading = after.trimmingCharacters(in: .whitespaces)
        while heading.hasSuffix("#") { heading.removeLast() }   // "## Terms ##"
        return heading.trimmingCharacters(in: .whitespaces)
    }

    static func isIndented(_ line: String) -> Bool {
        if line.first == "\t" { return true }
        return line.prefix(while: { $0 == " " }).count >= 2
    }

    static let bulletCharacters: Set<Character> = ["-", "*", "+", "•"]

    /// The text after a top-level bullet (`- `, `* `, `+ `, `• `), or nil when the line isn't one.
    static func topLevelBulletContent(_ line: String) -> String? {
        let t = line.drop(while: { $0 == " " })
        guard let first = t.first, bulletCharacters.contains(first) else { return nil }
        let after = t.dropFirst()
        guard after.isEmpty || after.first!.isWhitespace else { return nil }
        let content = after.trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : content
    }

    /// A sub-line without its bullet, if it has one.
    static func stripBullet(_ trimmed: String) -> String {
        guard let first = trimmed.first, bulletCharacters.contains(first) else { return trimmed }
        let after = trimmed.dropFirst()
        guard after.isEmpty || after.first!.isWhitespace else { return trimmed }
        return after.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Entries

    static let heardMarker = RegexBox(#"(?<![\p{L}\p{N}])(?:mis)?heard(?:\s+as)?\s*:"#, options: [.caseInsensitive])
    static let heardAtStart = RegexBox(#"^(?:mis)?heard(?:\s+as)?\s*:"#, options: [.caseInsensitive])

    /// Characters that may separate a term from its description, or a description from an inline `heard:`.
    static let separatorCharacters: Set<Character> = ["—", "–", "-", ":", ",", ";", "(", "["]

    /// Parses the text after a top-level bullet. Returns the entry and whether it had an inline `heard:`.
    static func parseEntry(_ content: String) -> (GlossaryEntry, Bool)? {
        var rest = Substring(content)
        var pinned = false
        if rest.hasPrefix("!") {
            pinned = true
            rest = rest.dropFirst().drop(while: { $0.isWhitespace })
        }
        var term: Substring
        var after: Substring
        var isBold = false
        if rest.hasPrefix("**") || rest.hasPrefix("__") {
            let marker = String(rest.prefix(2))
            let body = rest.dropFirst(2)
            guard let close = body.range(of: marker) else { return nil }
            term = body[..<close.lowerBound]
            after = body[close.upperBound...]
            isBold = true
        } else {
            (term, after) = splitPlain(rest)
            // "- CORSIA (heard: a, b): description": the bracketed list belongs after the term.
            let termText = String(term)
            if let match = heardMarker.firstMatch(in: termText), let r = Range(match.range, in: termText) {
                var cut = r.lowerBound
                if let open = termText[..<cut].lastIndex(where: { !$0.isWhitespace }), termText[open] == "(" || termText[open] == "[" {
                    cut = open
                }
                let moved = String(termText[cut...])
                let tail = String(after)
                after = Substring(tail.trimmingCharacters(in: .whitespaces).isEmpty ? moved : moved + " — " + tail)
                term = Substring(termText[..<cut])
            }
        }
        term = term.drop(while: { $0.isWhitespace })
        if term.hasPrefix("!") {
            pinned = true
            term = term.dropFirst()
        }
        var termText = term.trimmingCharacters(in: .whitespaces)
        while let last = termText.last, last == ":" || last == "—" || last == "–" {   // "**CORSIA:** …"
            termText.removeLast()
            termText = termText.trimmingCharacters(in: .whitespaces)
        }
        guard !termText.isEmpty else { return nil }
        let lowered = termText.lowercased()
        if lowered == "heard" || lowered == "misheard" || lowered == "heard as" { return nil }
        // A long plain bullet is prose, not a term: keep it as a note.
        if !isBold, after.isEmpty, termText.split(whereSeparator: \.isWhitespace).count > 6 { return nil }

        let afterText = String(after)
        var description = trimSeparators(after)
        var heard: [String] = []
        var inline = false
        if let match = heardMarker.firstMatch(in: afterText) {
            let r = Range(match.range, in: afterText)!
            let list = heardListRange(in: afterText, markerEnd: r.upperBound, markerStart: r.lowerBound)
            heard = splitHeard(String(afterText[list]))
            let before = trimSeparators(afterText[..<r.lowerBound])
            // Text after a bracketed list ("(heard: a) — description") is still description.
            let rest = list.upperBound < afterText.endIndex
                ? trimSeparators(afterText[afterText.index(after: list.upperBound)...]) : ""
            description = [before, rest].filter { !$0.isEmpty }.joined(separator: " ")
            inline = true
        }
        termText = collapseSpaces(termText)
        description = collapseSpaces(description)
        return (GlossaryEntry(term: termText, description: description.isEmpty ? nil : description,
                              heard: mergeHeard([], heard), pinned: pinned), inline)
    }

    /// Splits a plain (not bold) term from its description at the earliest separator:
    /// `—` or `–` anywhere, `-` with spaces around it, or `:` followed by a space.
    static func splitPlain(_ s: Substring) -> (Substring, Substring) {
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            // Separators inside brackets don't split ("Term (heard: a) — description").
            if c == "(" || c == "[", let close = s[next...].firstIndex(of: c == "(" ? ")" : "]") {
                i = s.index(after: close)
                continue
            }
            if c == "—" || c == "–" { return (s[..<i], s[next...]) }
            if c == "-", i > s.startIndex, s[s.index(before: i)].isWhitespace, next < s.endIndex, s[next].isWhitespace {
                return (s[..<i], s[next...])
            }
            if c == ":", next == s.endIndex || s[next].isWhitespace { return (s[..<i], s[next...]) }
            i = next
        }
        return (s, s[s.endIndex...])
    }

    /// Runs of spaces (left behind by a removed comment, say) become one.
    static func collapseSpaces(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    static func trimSeparators(_ s: Substring) -> String {
        var s = s
        while let f = s.first, f.isWhitespace || (separatorCharacters.contains(f) && f != "(" && f != "[") { s.removeFirst() }
        while let l = s.last, l.isWhitespace || separatorCharacters.contains(l) { s.removeLast() }
        return String(s)
    }

    /// Where the list after a `heard:` marker ends: at the matching `)` or `]` when the marker follows an opening
    /// bracket ("(heard: a, b) — more"), otherwise at the end of the text. The upper bound is the closing bracket.
    static func heardListRange(in text: String, markerEnd: String.Index, markerStart: String.Index) -> Range<String.Index> {
        let before = text[..<markerStart].reversed().drop(while: { $0.isWhitespace }).first
        if let open = before, open == "(" || open == "[" {
            let close: Character = open == "(" ? ")" : "]"
            if let end = text[markerEnd...].firstIndex(of: close) { return markerEnd..<end }
        }
        return markerEnd..<text.endIndex
    }

    /// The mishearings after `heard:` at the start of a sub-line, or nil when it isn't a `heard:` line.
    static func heardList(atStartOf content: String) -> [String]? {
        guard let match = heardAtStart.firstMatch(in: content) else { return nil }
        let r = Range(match.range, in: content)!
        return splitHeard(String(content[r.upperBound...]))
    }

    static let quoteCharacters: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "`", "*", "_"]

    static func splitHeard(_ s: String) -> [String] {
        var s = Substring(s)
        while let l = s.last, l == ")" || l == "]" || l.isWhitespace || l == "." { s.removeLast() }
        return s.split(whereSeparator: { $0 == "," || $0 == ";" }).map { part in
            var p = part.trimmingCharacters(in: .whitespaces)[...]
            while let f = p.first, quoteCharacters.contains(f) { p.removeFirst() }
            while let l = p.last, quoteCharacters.contains(l) { p.removeLast() }
            return p.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    /// Appends mishearings that aren't already there (case-insensitive), keeping order.
    static func mergeHeard(_ existing: [String], _ new: [String]) -> [String] {
        var out = existing
        var seen = Set(existing.map { $0.lowercased() })
        for h in new where seen.insert(h.lowercased()).inserted { out.append(h) }
        return out
    }
}
