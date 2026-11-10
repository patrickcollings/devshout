import Foundation

/// The glossary part of Whisper's prompt, and how much of the glossary it holds (for Settings).
public struct WhisperVocabulary: Sendable, Hashable {
    /// Comma-separated correct spellings ("CORSIA, NDC, My Supply, Siobhán Murphy"). Empty when nothing fits.
    public var prompt: String
    /// The terms in the prompt, in order.
    public var includedTerms: [String]
    /// How many distinct terms could have gone in (pinned entries, People and Terms; not Patterns).
    public var candidateCount: Int
    /// Tokens the prompt uses, by the builder's `TokenCounter`.
    public var tokenCount: Int
    public var tokenBudget: Int

    public init(prompt: String, includedTerms: [String], candidateCount: Int, tokenCount: Int, tokenBudget: Int) {
        self.prompt = prompt
        self.includedTerms = includedTerms
        self.candidateCount = candidateCount
        self.tokenCount = tokenCount
        self.tokenBudget = tokenBudget
    }

    /// How many terms fitted.
    public var includedCount: Int { includedTerms.count }

    /// "Whisper sees 37 of 120 terms (176/180 tokens)" for Settings.
    public var summary: String {
        "Whisper sees \(includedCount) of \(candidateCount) \(candidateCount == 1 ? "term" : "terms") (\(tokenCount)/\(tokenBudget) tokens)"
    }
}

/// Builds Whisper's vocabulary prompt from the glossary (PLAN §6.4). Whisper's prompt holds 224 tokens:
/// about 180 go to the glossary and about 40 to the end of the previous chunk's text.
///
/// Order: pinned entries (`!`, in file order), then People, then Terms, each as its correct spelling, stopping at
/// the first term that would go over the budget (so the order in the file is respected). Patterns (`{n}`) are left out,
/// and a term that appears twice is used once.
public struct WhisperPromptBuilder: Sendable {
    public static let defaultGlossaryBudget = 180
    public static let defaultPreviousTextBudget = 40
    static let joiner = ", "

    public var tokenCounter: any TokenCounter
    public var glossaryBudget: Int
    public var previousTextBudget: Int

    public init(tokenCounter: any TokenCounter = ApproximateTokenCounter(),
                glossaryBudget: Int = WhisperPromptBuilder.defaultGlossaryBudget,
                previousTextBudget: Int = WhisperPromptBuilder.defaultPreviousTextBudget) {
        self.tokenCounter = tokenCounter
        self.glossaryBudget = glossaryBudget
        self.previousTextBudget = previousTextBudget
    }

    /// The correct spellings in prompt order, before the budget is applied.
    public static func candidates(_ glossary: Glossary) -> [String] {
        let entries = glossary.allEntries.filter { !$0.entry.isPattern }
        let pinned = entries.filter { $0.entry.pinned }.map(\.entry)
        let people = entries.filter { !$0.entry.pinned && $0.kind == .people }.map(\.entry)
        let terms = entries.filter { !$0.entry.pinned && $0.kind == .terms }.map(\.entry)
        var seen = Set<String>()
        var out: [String] = []
        for entry in pinned + people + terms {
            let term = entry.term.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            out.append(term)
        }
        return out
    }

    public func vocabulary(for glossary: Glossary) -> WhisperVocabulary {
        let all = WhisperPromptBuilder.candidates(glossary)
        var included: [String] = []
        var prompt = ""
        var tokens = 0
        for term in all {
            let next = included.isEmpty ? term : prompt + WhisperPromptBuilder.joiner + term
            let count = tokenCounter.count(next)
            guard count <= glossaryBudget else { break }
            included.append(term)
            prompt = next
            tokens = count
        }
        return WhisperVocabulary(prompt: prompt, includedTerms: included, candidateCount: all.count,
                                 tokenCount: tokens, tokenBudget: glossaryBudget)
    }

    /// The end of the previous chunk's text that fits `previousTextBudget`, cut at a word boundary.
    /// Nil when there is no previous text or not even its last word fits.
    public func previousTextTail(_ text: String?) -> String? {
        guard let text else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        var best: String?
        var lo = 1, hi = words.count
        // Token counts grow with the number of words, so binary-search the longest tail that fits.
        while lo <= hi {
            let mid = (lo + hi) / 2
            let tail = words.suffix(mid).joined(separator: " ")
            if tokenCounter.count(tail) <= previousTextBudget {
                best = tail
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }

    /// The context for one Whisper chunk: the glossary prompt and the tail of the previous chunk's text.
    public func context(glossary: Glossary, previousText: String? = nil, language: String = "en") -> TranscriptionContext {
        context(vocabulary: vocabulary(for: glossary), previousText: previousText, language: language)
    }

    /// The same, reusing a vocabulary built once per recording.
    public func context(vocabulary: WhisperVocabulary, previousText: String? = nil, language: String = "en") -> TranscriptionContext {
        TranscriptionContext(language: language,
                             vocabularyPrompt: vocabulary.prompt.isEmpty ? nil : vocabulary.prompt,
                             previousText: previousTextTail(previousText))
    }
}
