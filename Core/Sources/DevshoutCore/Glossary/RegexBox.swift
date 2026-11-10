import Foundation

/// An `NSRegularExpression` that can be kept in `static let`s and `Sendable` values under Swift 6.
/// `NSRegularExpression` is immutable and documented as thread-safe once made.
final class RegexBox: @unchecked Sendable {
    let regex: NSRegularExpression

    /// Crashes on an invalid pattern: only for patterns written in this module (or built from escaped input).
    init(_ pattern: String, options: NSRegularExpression.Options = []) {
        // swiftlint:disable:next force_try
        self.regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// Nil when the pattern doesn't compile (for patterns built from user input).
    init?(compiling pattern: String, options: NSRegularExpression.Options = []) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        self.regex = regex
    }

    func matches(in text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
    }

    func firstMatch(in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
    }
}

extension String {
    /// The substring for an `NSRange` from a match on this string (empty when the range is not found).
    func substring(_ range: NSRange) -> String {
        guard range.location != NSNotFound, let r = Range(range, in: self) else { return "" }
        return String(self[r])
    }
}
