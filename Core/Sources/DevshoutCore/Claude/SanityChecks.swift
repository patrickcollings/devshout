import Foundation

/// Tidy must edit, not summarise or answer: the output's word count has to stay within 70–130% of the input's.
public enum TidyLengthCheck {
    public static let minimumRatio = 0.7
    public static let maximumRatio = 1.3
    /// Very short dictations swing a lot in percentage terms ("um, yes, OK" → "Yes, OK."), so a difference of this
    /// many words or fewer always passes.
    public static let shortInputSlack = 3

    /// Nil when the output is acceptable, else the reason it was rejected.
    public static func failureReason(raw: String, output: String) -> String? {
        let input = wordCount(raw)
        let produced = wordCount(output)
        if abs(input - produced) <= shortInputSlack { return nil }
        let ratio = input == 0 ? Double.infinity : Double(produced) / Double(input)
        if ratio < minimumRatio {
            return "Tidy output was much shorter than the dictation (\(produced) words from \(input)), so it may have summarised it"
        }
        if ratio > maximumRatio {
            return "Tidy output was much longer than the dictation (\(produced) words from \(input)), so it may have answered it instead of tidying it"
        }
        return nil
    }

    /// Words containing at least one letter or digit (Markdown bullets and dashes don't count).
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .count
    }
}

/// Structure must keep every fact. Numbers, ticket IDs, file paths and glossary terms found in the raw text but
/// not in the output become a warning; they never block the paste.
public enum CoverageCheck {
    /// Items in `raw` that `output` seems to have lost, in the order they first appear in `raw`.
    public static func missingItems(raw: String, output: String, glossaryTerms: [String] = []) -> [String] {
        var missing: [String] = []
        func add(_ item: String) { if !missing.contains(item) { missing.append(item) } }

        // Ticket IDs: AB-1234 (also accepts "ab-1234" in the output).
        let outputIDs = Set(matches(of: ticketPattern, in: output).map { $0.uppercased() })
        let rawIDs = matches(of: ticketPattern, in: raw)
        for id in rawIDs where !outputIDs.contains(id.uppercased()) { add(id) }

        // File paths.
        let rawPaths = filePaths(in: raw)
        for path in rawPaths where !output.contains(path) { add(path) }

        // Numbers, ignoring the digits of ticket IDs and paths already checked.
        let rawForNumbers = removing(rawPaths, from: removing(ticketPattern, from: raw))
        let outputForNumbers = removing(filePaths(in: output), from: removing(ticketPattern, from: output))
        let outputNumbers = Set(matches(of: numberPattern, in: outputForNumbers).map(normaliseNumber))
        for number in matches(of: numberPattern, in: rawForNumbers)
            where !outputNumbers.contains(normaliseNumber(number)) { add(number) }

        // Glossary terms said in the dictation.
        for term in glossaryTerms {
            let term = term.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, containsWord(term, in: raw), !containsWord(term, in: output) else { continue }
            add(term)
        }
        return missing
    }

    /// `["may have dropped: AB-1234, 20%"]`, or [] when nothing is missing.
    public static func warnings(raw: String, output: String, glossaryTerms: [String] = []) -> [String] {
        let missing = missingItems(raw: raw, output: output, glossaryTerms: glossaryTerms)
        return missing.isEmpty ? [] : ["may have dropped: " + missing.joined(separator: ", ")]
    }

    /// The terms of a glossary, in either form `TextCleaner.clean` may be given:
    /// - the Claude rendering (`GlossaryRenderer.forClaude`): `- CORSIA — meaning — heard: core sea` lines under
    ///   `Terms (…):` and `People (…):` labels;
    /// - raw `glossary.md`: `- **CORSIA** — …` (also `- !**CORSIA**`), or plain `- CORSIA` under `## Terms` / `## People`.
    /// Patterns with placeholders such as `AB-{n}` are skipped (ticket IDs are checked separately), and so are the
    /// bullets of Style and other free-text sections.
    public static func glossaryTerms(in glossary: String) -> [String] {
        var terms: [String] = []
        func add(_ term: String) {
            var term = term.trimmingCharacters(in: .whitespaces)
            if term.hasPrefix("!") { term = String(term.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard !term.isEmpty, !term.contains("{"), !terms.contains(term) else { return }
            terms.append(term)
        }

        var inEntrySection = false
        for rawLine in glossary.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
                inEntrySection = line.hasPrefix("##") && (heading.hasPrefix("terms") || heading.hasPrefix("people"))
                continue
            }
            if !line.hasPrefix("-"), !line.hasPrefix("*"), line.hasSuffix(":") {
                let label = line.lowercased()
                inEntrySection = label.hasPrefix("terms") || label.hasPrefix("people")
                continue
            }
            // Bold terms count wherever they are.
            let bold = matches(of: #"\*\*([^*\n]+?)\*\*"#, in: line, group: 1)
            if !bold.isEmpty {
                // Only the bullet's own term, not bold words in a description or a style note.
                if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("-!") || line.hasPrefix("- !") {
                    add(bold[0])
                }
                continue
            }
            // Plain bullets only inside Terms and People (indented `heard:` sub-bullets are skipped).
            guard inEntrySection, rawLine.first == "-" || rawLine.first == "*", line.count > 2 else { continue }
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            if body.lowercased().hasPrefix("heard:") { continue }
            let term = body.components(separatedBy: " — ").first ?? body
            add(term.components(separatedBy: " - ").first ?? term)
        }
        return terms
    }

    // MARK: - Patterns

    static let ticketPattern = #"\b[A-Za-z]{2,5}-\d+\b"#
    static let slashPathPattern = #"(?:~|\.{1,2})?(?:/[A-Za-z0-9_.\-]+)+/?|[A-Za-z0-9_.\-]+(?:/[A-Za-z0-9_.\-]+)+/?"#
    static let fileNamePattern = #"\b[A-Za-z0-9_\-]+(?:\.[A-Za-z0-9_\-]+)*\.(?:swift|md|json|ya?ml|toml|txt|sh|py|js|jsx|ts|tsx|rb|go|rs|java|kt|c|h|m|mm|cpp|hpp|css|scss|html|sql|plist|xcconfig|env|lock)\b"#

    /// `Core/Sources/Foo.swift`, `./x`, `~/y/z`, `/usr/bin` and bare file names with an extension (`PLAN.md`).
    /// A single slash between two plain words ("and/or", "input/output") isn't a path.
    static func filePaths(in text: String) -> [String] {
        var paths: [String] = []
        for candidate in matches(of: slashPathPattern, in: text) {
            let trimmed = candidate.hasSuffix(".") ? String(candidate.dropLast()) : candidate
            let rooted = trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".")
            let slashes = trimmed.filter { $0 == "/" }.count
            let hasExtension = trimmed.split(separator: "/").last?.contains(".") ?? false
            if rooted || slashes >= 2 || hasExtension, !paths.contains(trimmed) { paths.append(trimmed) }
        }
        let withoutSlashPaths = removing(paths, from: text)
        for name in matches(of: fileNamePattern, in: withoutSlashPaths) where !paths.contains(name) {
            paths.append(name)
        }
        return paths
    }
    /// 42, 3.5, 1,000, 20%. A lone digit counts too.
    static let numberPattern = #"(?<![\w.])\d+(?:[.,]\d+)*%?"#

    /// "1,000" and "1000" match, and "20%" matches "20" ("20 per cent").
    static func normaliseNumber(_ number: String) -> String {
        number.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "%", with: "")
    }

    static func matches(of pattern: String, in text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: group), in: text).map { String(text[$0]) }
        }
    }

    static func removing(_ pattern: String, from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }

    /// Removes literal strings, longest first.
    static func removing(_ literals: [String], from text: String) -> String {
        literals.sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: $1, with: " ") }
    }

    /// Case-insensitive, whole words.
    static func containsWord(_ word: String, in text: String) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
