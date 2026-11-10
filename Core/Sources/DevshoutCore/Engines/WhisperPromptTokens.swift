import Foundation

/// Builds the `promptTokens` WhisperKit conditions each chunk on: the glossary's vocabulary prompt, then the tail of
/// the previous chunk's text (PLAN §4.2, §6.4).
///
/// Whisper's prompt is limited to 224 tokens (half the 448-token decoder context). WhisperKit puts
/// `<|startofprev|>` in front of our tokens and keeps only the last 223, so `maxContentTokens` is 223 and the whole
/// prompt, marker included, stays within 224.
public enum WhisperPromptTokens {
    /// Whisper's prompt limit, including `<|startofprev|>`.
    public static let maxPromptTokens = 224
    /// What is left for our tokens once WhisperKit adds `<|startofprev|>`.
    public static let maxContentTokens = maxPromptTokens - 1
    /// Tokens of previous-chunk text kept when the vocabulary prompt needs the room.
    public static let previousTextBudget = 40

    /// Joins vocabulary and previous-text tokens within `maxContent` tokens.
    ///
    /// - The previous text keeps its *last* tokens (the words just before this chunk): at least `previousBudget` of
    ///   them when it has that many, more when the vocabulary leaves room.
    /// - The vocabulary keeps its *first* tokens (pinned and most important terms come first in the glossary).
    /// - Order: vocabulary, then previous text, so the prompt ends with the words that came just before.
    public static func assemble(vocabulary: [Int], previous: [Int],
                                maxContent: Int = maxContentTokens,
                                previousBudget: Int = previousTextBudget) -> [Int] {
        let cap = max(0, maxContent)
        guard cap > 0 else { return [] }
        let previousKeep = min(previous.count, cap, max(previousBudget, cap - vocabulary.count))
        let vocabularyKeep = min(vocabulary.count, cap - previousKeep)
        return Array(vocabulary.prefix(vocabularyKeep)) + Array(previous.suffix(previousKeep))
    }

    /// The text to encode for each part, or nil when there is nothing to say. Whisper prompts start with a space,
    /// as the text it was trained on does.
    public static func promptText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = TranscriptText.normalise(text)
        return trimmed.isEmpty ? nil : " " + trimmed
    }
}
