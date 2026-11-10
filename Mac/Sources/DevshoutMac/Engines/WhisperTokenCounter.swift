// Counts tokens with the loaded WhisperKit tokenizer, for WhisperPromptBuilder's budget and the Settings preview
// ("Whisper sees 37 of 120 terms (176/180 tokens)").
//
// Written against argmax-oss-swift 1.1.1 (WhisperKit `WhisperTokenizer`) without a Mac to compile on. Unsure of:
// - whether `WhisperTokenizer.encode(text:)` is safe to call from several threads at once. It is read-only in
//   swift-transformers as far as the source shows; calls are made under our lock anyway, so they never overlap.

import DevshoutCore
import Foundation
import WhisperKit

/// A `TokenCounter` backed by WhisperKit's tokenizer once `WhisperEngine` has loaded it; until then (and after
/// unload) it falls back to `ApproximateTokenCounter`.
public final class WhisperTokenCounter: TokenCounter, @unchecked Sendable {
    private let lock = NSLock()
    private var tokenizer: (any WhisperTokenizer)?
    private let fallback = ApproximateTokenCounter()

    public init() {}

    /// Whether counts come from the real tokenizer.
    public var usesWhisperTokenizer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tokenizer != nil
    }

    /// Tokens `text` takes up in a Whisper prompt (encoded with a leading space, special tokens left out, as
    /// `WhisperEngine` builds its prompt).
    public func count(_ text: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let tokenizer else { return fallback.count(text) }
        guard let promptText = WhisperPromptTokens.promptText(text) else { return 0 }
        return Self.encode(promptText, with: tokenizer).count
    }

    /// Prompt tokens for `text`, or nil before the tokenizer is loaded.
    func encode(_ text: String) -> [Int]? {
        lock.lock()
        defer { lock.unlock() }
        guard let tokenizer else { return nil }
        return Self.encode(text, with: tokenizer)
    }

    func setTokenizer(_ tokenizer: (any WhisperTokenizer)?) {
        lock.lock()
        self.tokenizer = tokenizer
        lock.unlock()
    }

    static func encode(_ text: String, with tokenizer: any WhisperTokenizer) -> [Int] {
        let specialBegin = tokenizer.specialTokens.specialTokenBegin
        return tokenizer.encode(text: text).filter { $0 < specialBegin }
    }
}
