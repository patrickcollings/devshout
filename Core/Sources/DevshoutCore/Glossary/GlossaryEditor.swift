import Foundation

/// Small edits to the glossary's text that keep everything else exactly as Patrick wrote it,
/// for "Add correction to glossary" in History (PLAN §6.7, which writes to the same `glossary.md`).
public enum GlossaryEditor {
    /// Where a new entry goes when the term isn't in the glossary yet.
    public enum CorrectionKind: String, Codable, Sendable, Hashable, CaseIterable {
        case term, person

        var section: GlossarySectionKind { self == .person ? .people : .terms }
        var heading: String { self == .person ? "People" : "Terms" }
    }

    /// Adds `heard` as a mishearing of `term`.
    /// - If the term has an entry (matched case-insensitively), `heard` is added to its `heard:` list,
    ///   or a `  - heard:` sub-bullet is added under it. Nothing changes if it is already listed.
    /// - Otherwise a new entry goes at the end of the first Terms (or People) section, which is added if missing.
    /// With `heard == nil` only the entry is added (when missing). The result uses LF line breaks and ends with one.
    public static func addingCorrection(heard: String?, term: String, kind: CorrectionKind = .term,
                                        to markdown: String) -> String {
        let term = clean(term)
        guard !term.isEmpty else { return markdown }
        var heard = heard.map(clean)
        if let h = heard, h.isEmpty || h.lowercased() == term.lowercased() { heard = nil }

        let parsed = GlossaryParser.parseWithLocations(markdown)
        var lines = parsed.lines

        if let loc = parsed.entries.first(where: { loc in
            parsed.glossary.sections[loc.section].items[loc.item].entry?.term.lowercased() == term.lowercased()
        }) {
            guard let heard else { return markdown }
            let entry = parsed.glossary.sections[loc.section].items[loc.item].entry!
            if entry.heard.contains(where: { $0.lowercased() == heard.lowercased() }) { return markdown }
            if let line = loc.heardLine, let edited = appending(heard, toListIn: lines[line]) {
                lines[line] = edited
            } else if loc.heardLine == nil, loc.inlineHeard, let edited = appending(heard, toListIn: lines[loc.line]) {
                lines[loc.line] = edited
            } else {
                lines.insert("  - heard: \(heard)", at: loc.lastLine + 1)
            }
            return lines.joined(separator: "\n") + "\n"
        }

        var newLines = ["- **\(term)**"]
        if let heard { newLines.append("  - heard: \(heard)") }

        if let s = parsed.glossary.sections.firstIndex(where: { $0.kind == kind.section }),
           let headingLine = parsed.headingLines[s] {
            let nextHeading = parsed.headingLines[(s + 1)...].compactMap { $0 }.first ?? lines.count
            var insertAt = headingLine + 1
            for i in stride(from: nextHeading - 1, to: headingLine, by: -1)
            where !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt = i + 1
                break
            }
            lines.insert(contentsOf: newLines, at: insertAt)
        } else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines.append("## \(kind.heading)")
            lines.append(contentsOf: newLines)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One line of input: no line breaks, no commas (they separate mishearings), no surrounding spaces.
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: ";", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Adds an item to the `heard:` list on a line: after its last item, inside a closing bracket and before a
    /// trailing full stop or comment, so "(heard: a)." becomes "(heard: a, b)." and "heard: a." becomes "heard: a, b.".
    /// Nil when the marker can't be found outside a comment (the caller then adds a sub-bullet instead).
    static func appending(_ item: String, toListIn line: String) -> String? {
        // Work on the part before any comment; the parser ignores what is inside it.
        let commentStart = line.range(of: "<!--")?.lowerBound ?? line.endIndex
        let visible = String(line[..<commentStart])
        guard let match = GlossaryParser.heardMarker.firstMatch(in: visible),
              let marker = Range(match.range, in: visible) else {
            return nil
        }
        let list = GlossaryParser.heardListRange(in: visible, markerEnd: marker.upperBound, markerStart: marker.lowerBound)
        var end = list.upperBound
        // Step back over spaces, full stops and (for an unbracketed list) closing brackets at the end of the list.
        while end > list.lowerBound {
            let prev = visible.index(before: end)
            let c = visible[prev]
            let isUnbracketedEnd = list.upperBound == visible.endIndex && (c == ")" || c == "]")
            guard c.isWhitespace || c == "." || isUnbracketedEnd else { break }
            end = prev
        }
        let isEmptyList = end == list.lowerBound
        // `visible` is a prefix of `line`, so the same UTF-8 offset splits both.
        let offset = visible.utf8.distance(from: visible.startIndex, to: end)
        let split = line.utf8.index(line.utf8.startIndex, offsetBy: offset)
        return String(line[..<split]) + (isEmptyList ? " " : ", ") + item + String(line[split...])
    }
}
