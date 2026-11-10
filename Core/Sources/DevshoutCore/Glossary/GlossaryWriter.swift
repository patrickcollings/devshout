import Foundation

/// Writes a `Glossary` back to Markdown in the canonical §6.1 form. Notes (free text, comments, blank lines and
/// unrecognised lines) are written exactly as they were read; entries are written as
/// `- **Term** — description` with a `  - heard: a, b` sub-bullet. `GlossaryParser.parse` of the output gives
/// back an equal glossary. (An HTML comment on the same line as an entry is not kept.)
///
/// The app's glossary editor saves Patrick's text as typed (`GlossaryFile.save(text:)`); this writer is for
/// glossaries built in code. "Add correction" edits the text in place instead (`GlossaryEditor`).
public enum GlossaryWriter {
    public static func markdown(_ glossary: Glossary) -> String {
        var out: [String] = []
        for section in glossary.sections {
            if let heading = section.heading { out.append(heading.isEmpty ? "##" : "## \(heading)") }
            for item in section.items {
                switch item {
                case .note(let note): out.append(note.raw)
                case .entry(let entry): out.append(contentsOf: lines(for: entry))
                }
            }
        }
        return out.isEmpty ? "" : out.joined(separator: "\n") + "\n"
    }

    /// The Markdown lines for one entry.
    public static func lines(for entry: GlossaryEntry) -> [String] {
        var first = "- " + (entry.pinned ? "!" : "") + "**\(entry.term)**"
        if let d = entry.description, !d.isEmpty { first += " — \(d)" }
        var lines = [first]
        if !entry.heard.isEmpty { lines.append("  - heard: " + entry.heard.joined(separator: ", ")) }
        lines.append(contentsOf: entry.notes.map { "  - \($0)" })
        return lines
    }
}
