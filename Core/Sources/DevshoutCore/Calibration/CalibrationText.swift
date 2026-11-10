import Foundation

/// Words for scoring a calibration reading: `BenchText`'s normalisation, with numbers written one way.
///
/// The script has numbers and dates in it on purpose, and engines disagree about how to write them ("twenty
/// per cent", "20%", "the fourteenth", "the 14th"). Those are differences of style, not of hearing, so both the
/// sentence and the transcript are rewritten the same way before they are compared: number words become digits,
/// ordinals become "14th", and "%" and "per cent" become "percent". Because both sides go through the same
/// function, a word that only looks like a number ("the second one") can never create a difference by itself.
public enum CalibrationText {
    public static func words(_ text: String) -> [String] {
        canonicalNumbers(BenchText.words(text.replacingOccurrences(of: "%", with: " percent ")))
    }

    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let unitOrdinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
    ]
    static let teenOrdinals: [String: Int] = [
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
    ]
    static let tenOrdinals: [String: Int] = [
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70,
        "eightieth": 80, "ninetieth": 90,
    ]

    private enum Last { case none, unit, teen, ten, hundred, thousand }

    /// Rewrites runs of number words in already-normalised words: ["twenty", "five"] → ["25"],
    /// ["three", "hundred", "and", "twenty"] → ["320"], ["thirty", "first"] → ["31st"], ["per", "cent"] → ["percent"].
    /// Digits said one by one ("one two three") stay separate numbers.
    static func canonicalNumbers(_ words: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < words.count {
            if words[i] == "per", i + 1 < words.count, words[i + 1] == "cent" {
                out.append("percent")
                i += 2
            } else if let (text, next) = number(in: words, at: i) {
                out.append(text)
                i = next
            } else {
                out.append(words[i])
                i += 1
            }
        }
        return out
    }

    /// The number starting at `start`, as digits (with an ordinal ending when its last word was one), and the index
    /// after it.
    private static func number(in words: [String], at start: Int) -> (String, Int)? {
        var total = 0
        var current = 0
        var last = Last.none
        var i = start
        var ordinal = false

        func isNumberWord(_ word: String) -> Bool {
            units[word] != nil || teens[word] != nil || tens[word] != nil || unitOrdinals[word] != nil
                || teenOrdinals[word] != nil || tenOrdinals[word] != nil
        }

        loop: while i < words.count {
            let word = words[i]
            if let value = units[word] ?? unitOrdinals[word] {
                guard last == .none || last == .ten || last == .hundred || last == .thousand else { break loop }
                current += value
                last = .unit
                ordinal = unitOrdinals[word] != nil
            } else if let value = teens[word] ?? teenOrdinals[word] ?? tens[word] ?? tenOrdinals[word] {
                guard last == .none || last == .hundred || last == .thousand else { break loop }
                current += value
                last = tens[word] != nil ? .ten : .teen
                ordinal = teenOrdinals[word] != nil || tenOrdinals[word] != nil
            } else if word == "hundred" {
                guard last == .unit || last == .teen, current > 0, current < 100 else { break loop }
                current *= 100
                last = .hundred
            } else if word == "thousand" {
                guard last != .none, last != .thousand, current > 0 else { break loop }
                total += current * 1000
                current = 0
                last = .thousand
            } else if word == "and" {
                // Only inside a number: "three hundred and twenty".
                guard last == .hundred || last == .thousand, i + 1 < words.count, isNumberWord(words[i + 1]) else {
                    break loop
                }
            } else {
                break loop
            }
            i += 1
            if ordinal { break }
        }
        guard last != .none else { return nil }
        let value = total + current
        return (ordinal ? "\(value)\(ordinalEnding(value))" : "\(value)", i)
    }

    static func ordinalEnding(_ value: Int) -> String {
        if (11...13).contains(value % 100) { return "th" }
        switch value % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    /// Whether a normalised word is a number (digits, possibly with an ordinal ending or a decimal point).
    static func isNumeric(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        return first.isNumber
    }
}
