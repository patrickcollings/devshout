import Foundation

/// One jargon sentence of the bench corpus.
public struct BenchSentence: Sendable, Hashable {
    /// "s01" … "s10".
    public var id: String
    /// The text to read aloud. May contain `⟨teammate⟩` placeholders for Patrick to swap for real names.
    public var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }

    /// Still has an unreplaced `⟨…⟩` placeholder.
    public var hasPlaceholder: Bool { text.contains("⟨") }
}

/// Parser for `bench/sentences.md`: one `- s01: text` per line; every other line is ignored.
public enum SentenceCorpusParser {
    public static func parse(_ markdown: String) throws -> [BenchSentence] {
        var out: [BenchSentence] = []
        for (offset, rawLine) in markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") else { continue }
            let item = line.dropFirst(2)
            guard let colon = item.firstIndex(of: ":") else { continue }
            let id = item[item.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            guard isSentenceID(id) else { continue }
            let text = item[item.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                throw BenchParseError.malformed(line: offset + 1, reason: "sentence \(id) has no text")
            }
            guard !out.contains(where: { $0.id == id }) else { throw BenchParseError.duplicateID(id) }
            out.append(BenchSentence(id: id, text: text))
        }
        guard !out.isEmpty else { throw BenchParseError.noEntries(file: "sentences") }
        return out
    }

    /// "s" followed by two or more digits.
    static func isSentenceID(_ id: String) -> Bool {
        guard id.hasPrefix("s"), id.count >= 3 else { return false }
        return id.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }
}
