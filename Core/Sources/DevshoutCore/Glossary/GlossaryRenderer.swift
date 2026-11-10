import Foundation

/// Renders a glossary for its consumers (PLAN §6.3).
public enum GlossaryRenderer {
    /// The whole glossary, compact, for the `<glossary>` block of Claude's system prompt:
    ///
    /// ```
    /// Terms (correct spelling — meaning — misheard as):
    /// - CORSIA — Carbon Offsetting and Reduction Scheme for International Aviation — heard: core sea, corsair
    ///
    /// People (correct spelling — misheard as):
    /// - Siobhán Murphy — heard: shiv on
    ///
    /// Patterns ({n} stands for a number):
    /// - AB-{n} — Linear ticket IDs — heard: a b {n}
    ///
    /// Style:
    /// Use British English.
    /// ```
    ///
    /// Sections are separated by a blank line. HTML comments and other blank lines are left out; unrecognised lines are kept. Returns "" for an empty glossary.
    public static func forClaude(_ glossary: Glossary) -> String {
        var blocks: [String] = []
        for section in glossary.sections {
            var body: [String] = []
            if section.kind.holdsEntries {
                for item in section.items {
                    switch item {
                    case .entry(let e): body.append(line(for: e))
                    case .note(let n):
                        let t = n.text.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { body.append(t) }
                    }
                }
            } else {
                var notes = section.notes
                if section.heading == nil {
                    // The "# Title" line says nothing useful to Claude.
                    notes.removeAll { $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("# ") }
                }
                let text = freeText(notes)
                if !text.isEmpty { body.append(text) }
            }
            guard !body.isEmpty else { continue }
            if let label = label(for: section) { body.insert(label, at: 0) }
            blocks.append(body.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// One compact line for an entry: `- Term — description — notes — heard: a, b`.
    public static func line(for entry: GlossaryEntry) -> String {
        var parts = [entry.term]
        if let d = entry.description, !d.isEmpty { parts.append(d) }
        if !entry.notes.isEmpty { parts.append(entry.notes.joined(separator: "; ")) }
        if !entry.heard.isEmpty { parts.append("heard: " + entry.heard.joined(separator: ", ")) }
        return "- " + parts.joined(separator: " — ")
    }

    static func label(for section: GlossarySection) -> String? {
        switch section.kind {
        case .terms: return "Terms (correct spelling — meaning — misheard as):"
        case .people: return "People (correct spelling — misheard as):"
        case .patterns: return "Patterns ({n} stands for a number):"
        case .style: return "Style:"
        case .other:
            guard let h = section.heading, !h.isEmpty else { return nil }
            return h.hasSuffix(":") ? h : "\(h):"
        }
    }

    /// Notes' visible text with leading and trailing blank lines removed and runs of blank lines collapsed.
    static func freeText(_ notes: [GlossaryNote]) -> String {
        var lines: [String] = []
        var pendingBlank = false
        for note in notes {
            let t = note.text
            if t.trimmingCharacters(in: .whitespaces).isEmpty {
                if !lines.isEmpty { pendingBlank = true }
                continue
            }
            if pendingBlank { lines.append("") }
            pendingBlank = false
            lines.append(t)
        }
        return lines.joined(separator: "\n")
    }
}
