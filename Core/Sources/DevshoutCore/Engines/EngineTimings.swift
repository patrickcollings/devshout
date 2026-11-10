import Foundation

/// A token or word with timings in seconds relative to the start of the audio the engine was given (the chunk).
/// Engines convert their own timing types into this, then `EngineTimings` makes `TimedWord`s relative to the recording.
public struct RawTiming: Sendable, Hashable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Pure helpers that turn engine timings into `TimedWord`s relative to the start of the recording.
public enum EngineTimings {
    /// SentencePiece's word-boundary marker (Parakeet's vocabulary uses it; FluidAudio turns it into a space).
    public static let wordBoundaryMarker: Character = "\u{2581}"

    /// Seconds from the start of the recording to the start of `chunk`.
    public static func offsetSeconds(of chunk: AudioChunk) -> TimeInterval {
        Double(chunk.startSample) / Double(AudioFormat.sampleRate)
    }

    /// Merges subword tokens (Parakeet/FluidAudio `tokenTimings`) into words.
    ///
    /// A token that starts with a space or `▁` begins a new word; any other token continues the current word, so
    /// punctuation sticks to the word before it ("world" + "." → "world."). Special tokens (`<blank>`, `<pad>`,
    /// `<unk>`, `<|…|>`) are dropped. Each word runs from its first token's start to its last token's end, plus
    /// `offset` seconds.
    public static func mergeSubwordTokens(_ tokens: [RawTiming], offset: TimeInterval = 0) -> [TimedWord] {
        var words: [TimedWord] = []
        var current = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0

        func flush() {
            let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                words.append(TimedWord(text: text, start: start + offset, end: max(end, start) + offset))
            }
            current = ""
        }

        for token in tokens {
            let piece = token.text
            if piece.isEmpty || isSpecialToken(piece) { continue }
            let startsWord = piece.first == " " || piece.first == wordBoundaryMarker
            let body = String(piece.drop(while: { $0 == " " || $0 == wordBoundaryMarker }))
            if body.isEmpty {
                // A bare boundary marker: the next token starts a new word.
                flush()
                continue
            }
            if startsWord || current.isEmpty {
                flush()
                current = body
                start = token.start
            } else {
                current += body
            }
            end = token.end
        }
        flush()
        return words
    }

    /// Converts whole-word timings (WhisperKit `wordTimestamps`) to `TimedWord`s: trims spaces, drops empty words and
    /// special tokens, adds `offset` seconds and keeps `end >= start`.
    public static func words(from timings: [RawTiming], offset: TimeInterval = 0) -> [TimedWord] {
        timings.compactMap { timing in
            let text = TranscriptText.stripSpecialTokens(timing.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TimedWord(text: text, start: timing.start + offset, end: max(timing.end, timing.start) + offset)
        }
    }

    /// `<blank>`, `<pad>`, `<unk>`, `<s>`, `</s>` and Whisper's `<|…|>` tokens.
    public static func isSpecialToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<|") && trimmed.hasSuffix("|>") { return true }
        return ["<blank>", "<pad>", "<unk>", "<s>", "</s>"].contains(trimmed)
    }
}

/// Clean-up of the text an engine returns, before it reaches the stitcher.
public enum TranscriptText {
    /// Removes Whisper special tokens such as `<|startoftranscript|>`, `<|en|>`, `<|0.00|>` and `<|endoftext|>`.
    public static func stripSpecialTokens(_ text: String) -> String {
        guard text.contains("<|") else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<|") {
            result += rest[rest.startIndex..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "|>") else {
                result += rest[open.lowerBound...]
                rest = ""
                break
            }
            // Keep the spacing sensible where a token sat between two words.
            result += " "
            rest = afterOpen[close.upperBound...]
        }
        result += rest
        return result
    }

    /// Strips special tokens, collapses runs of whitespace into one space and trims the ends.
    /// Casing and punctuation are left alone (Raw mode pastes this as it is).
    public static func normalise(_ text: String) -> String {
        stripSpecialTokens(text)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// True when Whisper has only repeated its vocabulary prompt back (a known failure on near-silent audio):
    /// the text has at least `minimumWords` words and, ignoring case and punctuation, appears inside the prompt.
    public static func isPromptEcho(_ text: String, prompt: String?, minimumWords: Int = 4) -> Bool {
        guard let prompt, !prompt.isEmpty else { return false }
        let words = comparableWords(text)
        guard words.count >= minimumWords else { return false }
        let promptWords = comparableWords(prompt)
        guard promptWords.count >= words.count else { return false }
        for start in 0...(promptWords.count - words.count) where promptWords[start] == words[0] {
            if Array(promptWords[start..<(start + words.count)]) == words { return true }
        }
        return false
    }

    static func comparableWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }
}

/// Audio adjustments engines need before inference.
public enum EngineAudio {
    /// Pads `samples` with trailing silence up to `minimumCount` (FluidAudio rejects audio under 0.3 s).
    public static func padded(_ samples: [Float], toAtLeast minimumCount: Int) -> [Float] {
        guard samples.count < minimumCount else { return samples }
        return samples + [Float](repeating: 0, count: minimumCount - samples.count)
    }

    /// Whether the audio is entirely silent (all samples within `threshold` of zero).
    public static func isSilent(_ samples: [Float], threshold: Float = 1e-4) -> Bool {
        samples.allSatisfy { abs($0) <= threshold }
    }
}
