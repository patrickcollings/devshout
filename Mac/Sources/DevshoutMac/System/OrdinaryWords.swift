// Whether a word is an ordinary English word, by the Mac's spelling checker. Voice calibration uses it to decide
// which learned mishearings are safe to replace everywhere: "causia" is not a word, so replacing it with CORSIA can't
// hurt; "component" is, so replacing it with "proponent" would rewrite normal sentences.

import AppKit
import Foundation

public enum OrdinaryWords {
    /// The words of `words` that the spelling checker accepts, as written or capitalised (so a name such as "vera"
    /// counts: replacing it everywhere would rewrite a real name). British English when the Mac has it, else English.
    /// `NSSpellChecker` is main-thread only.
    @MainActor
    public static func ordinary(among words: Set<String>) -> Set<String> {
        let checker = NSSpellChecker.shared
        let available = checker.availableLanguages
        let language = ["en_GB", "en"].first { available.contains($0) } ?? checker.language()
        func isSpelledCorrectly(_ word: String) -> Bool {
            let range = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                              inSpellDocumentWithTag: 0, wordCount: nil)
            return range.location == NSNotFound
        }
        return words.filter { word in
            guard word.contains(where: \.isLetter) else { return true }
            return isSpelledCorrectly(word) || isSpelledCorrectly(word.prefix(1).uppercased() + word.dropFirst())
        }
    }
}
