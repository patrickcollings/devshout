import Foundation

// Search for Settings → History: plain text matching over everything a recording says.

extension Recording {
    /// Every text kept for the recording: what was delivered, each clean version, and the transcript before and
    /// after glossary fixes.
    public var searchableTexts: [String] {
        ([deliveredText] + versions.map { Optional($0.text) } + [fixedText, rawText]).compactMap { $0 }
    }

    /// Whether the recording matches a search. Every word of the query must appear somewhere in the recording's
    /// texts (not necessarily in the same one, nor in that order), ignoring case and accents. A blank query matches
    /// everything.
    public func matches(search query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let texts = searchableTexts
        return words.allSatisfy { word in
            texts.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

extension Sequence where Element == Recording {
    /// The recordings that match the search, in their existing order.
    public func matching(search query: String) -> [Recording] {
        filter { $0.matches(search: query) }
    }
}
