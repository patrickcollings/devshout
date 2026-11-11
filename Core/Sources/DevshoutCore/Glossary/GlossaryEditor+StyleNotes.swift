import Foundation

/// Style notes, for what voice calibration learns about ordinary words (`LearnedStyleNote`). Kept apart from
/// `GlossaryEditor.addingCorrection` because a note is free text for Claude, not a replacement.
public extension GlossaryEditor {
    /// Adds each note as a `- ` bullet at the end of the first Style section, which is added at the end of the file
    /// when there is none. A note whose text is already in a Style section is not added again. Everything else
    /// stays exactly as written. The result uses LF line breaks and ends with one; with nothing to add, the text
    /// comes back unchanged.
    static func addingStyleNotes(_ notes: [String], to markdown: String) -> String {
        let parsed = GlossaryParser.parseWithLocations(markdown)
        let existing = parsed.glossary.sections.filter { $0.kind == .style }.flatMap(\.notes).map(\.text).joined(separator: "\n")
        var fresh: [String] = []
        for note in notes {
            let text = note.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty, !existing.contains(text), !fresh.contains(text) else { continue }
            fresh.append(text)
        }
        guard !fresh.isEmpty else { return markdown }

        var lines = parsed.lines
        let newLines = fresh.map { "- \($0)" }
        if let s = parsed.glossary.sections.firstIndex(where: { $0.kind == .style }), let headingLine = parsed.headingLines[s] {
            let nextHeading = parsed.headingLines[(s + 1)...].compactMap { $0 }.first ?? lines.count
            // After the section's last line that isn't blank (which may be the end of a comment).
            var insertAt = headingLine + 1
            for i in stride(from: nextHeading - 1, to: headingLine, by: -1)
            where !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt = i + 1
                break
            }
            lines.insert(contentsOf: newLines, at: insertAt)
        } else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines.append("## Style")
            lines.append(contentsOf: newLines)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
