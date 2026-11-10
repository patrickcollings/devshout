import Foundation

/// Reads numbers as they come out of speech-to-text, for ticket IDs and other `{n}` patterns:
/// digits ("1234", "12 34", "1 2 3 4"), spelled-out digits ("one two three four", "oh seven"),
/// pairs ("twelve thirty-four"), "double three", and cardinals ("one hundred and five", "two thousand and twelve").
/// Consecutive groups are concatenated, as people read ticket numbers: "twelve thirty four" → "1234".
enum SpokenNumbers {
    static let units: [String: Int] = [
        "zero": 0, "nought": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let fillers: Set<String> = ["oh", "double", "triple", "hundred", "thousand", "and"]

    /// Every word that can be part of a spoken number, longest first (for building regexes).
    static let allWords: [String] = (Array(units.keys) + Array(teens.keys) + Array(tens.keys) + Array(fillers))
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }

    /// A regex fragment matching a run of number tokens (digits or number words) separated by spaces or hyphens.
    /// The run is checked and trimmed by `parse`.
    static let runPattern: String = {
        let word = "(?:" + allWords.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
        let token = "(?:\\d+(?![\\p{L}\\p{N}])|" + word + ")"
        return token + "(?:[ \\t\\-]+" + token + ")*"
    }()

    struct Token {
        var text: String   // lowercased
        var end: String.Index
    }

    static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == " " || s[i] == "\t" || s[i] == "-" { i = s.index(after: i); continue }
            var j = i
            while j < s.endIndex, !(s[j] == " " || s[j] == "\t" || s[j] == "-") { j = s.index(after: j) }
            out.append(Token(text: s[i..<j].lowercased(), end: j))
            i = j
        }
        return out
    }

    /// Reads the number at the start of `s`. Returns its digits and where in `s` the number ends,
    /// or nil when `s` doesn't start with one. Words after the number are left alone.
    /// A lone "one" to "nine" (or "oh"/"zero") is too often an ordinary word ("the AB one"), so `parse` rejects it
    /// when `allowLoneUnitWord` is false. Digits, teens, tens and longer numbers are always read.
    static func parse(_ s: String, allowLoneUnitWord: Bool = true) -> (digits: String, end: String.Index)? {
        let toks = tokens(s)
        var i = 0
        var out = ""
        while i < toks.count, let (group, next, terminal) = group(toks, at: i) {
            out += group
            i = next
            if terminal { break }
        }
        guard !out.isEmpty, i > 0 else { return nil }
        if !allowLoneUnitWord, i == 1, units[toks[0].text] != nil { return nil }
        return (out, toks[i - 1].end)
    }

    static func isNumberToken(_ t: String) -> Bool {
        isDigits(t) || units[t] != nil || teens[t] != nil || tens[t] != nil || t == "oh" || t == "double" || t == "triple"
    }

    static func isDigits(_ t: String) -> Bool { !t.isEmpty && t.allSatisfy { $0.isASCII && $0.isNumber } }

    /// One group at `i`: its digits, the next token index, and whether the number ends after it.
    static func group(_ t: [Token], at i: Int) -> (String, Int, Bool)? {
        let w = t[i].text
        if isDigits(w) {
            // A run of three or more digits is a whole number already ("AB 1234 2 days ago").
            return (w, i + 1, w.count >= 3)
        }
        if w == "oh" {
            // Only a zero when more of the number follows ("oh seven"), so "AB 12 oh no" stays.
            guard i + 1 < t.count, isNumberToken(t[i + 1].text) else { return nil }
            return ("0", i + 1, false)
        }
        if w == "double" || w == "triple" {
            guard i + 1 < t.count, let d = digit(t[i + 1].text) else { return nil }
            return (String(repeating: d, count: w == "double" ? 2 : 3), i + 2, false)
        }
        guard let (value, next) = cardinal(t, at: i) else { return nil }
        return (String(value), next, false)
    }

    static func digit(_ w: String) -> String? {
        if let u = units[w] { return String(u) }
        if w == "oh" { return "0" }
        if w.count == 1, isDigits(w) { return w }
        return nil
    }

    /// 0…99 from a unit, teen, or tens with an optional unit ("thirty four").
    static func belowHundred(_ t: [Token], at i: Int) -> (Int, Int)? {
        guard i < t.count else { return nil }
        let w = t[i].text
        if let u = units[w] { return (u, i + 1) }
        if let v = teens[w] { return (v, i + 1) }
        if let v = tens[w] {
            if i + 1 < t.count, let u = units[t[i + 1].text], u > 0 { return (v + u, i + 2) }
            return (v, i + 1)
        }
        return nil
    }

    /// 0…999: "five", "thirty four", "one hundred", "one hundred and five", "nineteen hundred".
    static func belowThousand(_ t: [Token], at i: Int) -> (Int, Int)? {
        guard let (v, n) = belowHundred(t, at: i) else { return nil }
        guard n < t.count, t[n].text == "hundred", v > 0 else { return (v, n) }
        var value = v * 100
        var next = n + 1
        if let (rest, after) = optionalAnd(t, at: next, then: belowHundred) {
            value += rest
            next = after
        }
        return (value, next)
    }

    /// "two thousand", "two thousand and twelve", "three thousand four hundred", or a smaller number.
    static func cardinal(_ t: [Token], at i: Int) -> (Int, Int)? {
        guard let (v, n) = belowThousand(t, at: i) else { return nil }
        guard n < t.count, t[n].text == "thousand", v > 0 else { return (v, n) }
        var value = v * 1000
        var next = n + 1
        if let (rest, after) = optionalAnd(t, at: next, then: belowThousand) {
            value += rest
            next = after
        }
        return (value, next)
    }

    /// Parses `then` at `i`, allowing one "and" before it.
    static func optionalAnd(_ t: [Token], at i: Int, then: ([Token], Int) -> (Int, Int)?) -> (Int, Int)? {
        guard i < t.count else { return nil }
        if t[i].text == "and" { return then(t, i + 1) }
        return then(t, i)
    }
}
