import Foundation

public enum BenchParseError: Error, Sendable, Hashable, CustomStringConvertible {
    case noEntries(file: String)
    case duplicateID(String)
    case malformed(line: Int, reason: String)

    public var description: String {
        switch self {
        case .noEntries(let file): "No entries found in \(file)."
        case .duplicateID(let id): "Duplicate id: \(id)."
        case .malformed(let line, let reason): "Line \(line): \(reason)"
        }
    }
}

/// Parser for `bench/ramble-outline.md`.
///
/// A point starts with a heading `### 1. Label` (any heading level from `##` to `####` works). The lines under it
/// that start with one of these keys are read; everything else is ignored, so the file can carry free prose:
///
/// ```
/// ### 3. The buffer pool figure
/// - say: Talk about the default percentage … (guidance for the speaker)
/// - keywords: 12 | twelve ; percent | per cent
/// - retracted: ten percent
/// ```
///
/// `keywords` is a list of groups separated by `;`. A group is a list of alternatives separated by `|`. A point is
/// covered when every group has at least one alternative in the text. `retracted` lists alternatives separated by
/// `|` too. Point numbers must be 1, 2, 3 … in order.
public enum RambleOutlineParser {
    public static func parse(_ markdown: String) throws -> [RamblePoint] {
        var points: [RamblePoint] = []
        var current: (number: Int, label: String, line: Int, prompt: String?, groups: [KeywordGroup], retracted: [String])?

        func finish() throws {
            guard let c = current else { return }
            guard !c.groups.isEmpty else {
                throw BenchParseError.malformed(line: c.line, reason: "point \(c.number) has no '- keywords:' line")
            }
            points.append(RamblePoint(number: c.number, label: c.label, prompt: c.prompt, requirements: c.groups,
                                      retracted: c.retracted))
            current = nil
        }

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let heading = parseHeading(line) {
                try finish()
                guard heading.number == points.count + 1 else {
                    throw BenchParseError.malformed(line: lineNumber, reason: "expected point \(points.count + 1), found \(heading.number)")
                }
                current = (heading.number, heading.label, lineNumber, nil, [], [])
                continue
            }
            guard current != nil, line.hasPrefix("- ") else { continue }
            let item = line.dropFirst(2)
            guard let colon = item.firstIndex(of: ":") else { continue }
            let key = item[item.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = item[item.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "say":
                current?.prompt = value
            case "keywords":
                let groups = value.split(separator: ";", omittingEmptySubsequences: false).map { group in
                    KeywordGroup(alternatives: group.split(separator: "|", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) })
                }
                for group in groups where group.alternatives.contains(where: { BenchText.words($0).isEmpty }) {
                    throw BenchParseError.malformed(line: lineNumber, reason: "empty keyword or group")
                }
                current?.groups = groups
            case "retracted":
                let phrases = value.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if phrases.contains(where: { BenchText.words($0).isEmpty }) {
                    throw BenchParseError.malformed(line: lineNumber, reason: "a retracted phrase has no words (punctuation and symbols are ignored)")
                }
                current?.retracted = phrases
            default:
                break
            }
        }
        try finish()
        guard !points.isEmpty else { throw BenchParseError.noEntries(file: "ramble outline") }
        return points
    }

    /// "### 3. Label" → (3, "Label").
    private static func parseHeading(_ line: String) -> (number: Int, label: String)? {
        guard line.hasPrefix("##") else { return nil }
        let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        guard let dot = text.firstIndex(of: "."), let number = Int(text[text.startIndex..<dot]) else { return nil }
        let label = text[text.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (number, label)
    }
}
