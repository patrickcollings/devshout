import Foundation
@testable import DevshoutCore

enum GlossaryFixtures {
    static func text(_ name: String) throws -> String {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/glossary/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func glossary(_ name: String) throws -> Glossary {
        GlossaryParser.parse(try text(name))
    }
}

/// Counts characters, so budgets are easy to reason about in tests.
struct CharacterTokenCounter: TokenCounter {
    func count(_ text: String) -> Int { text.count }
}

/// Counts whitespace-separated words.
struct WordTokenCounter: TokenCounter {
    func count(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }
}

extension Glossary {
    func entry(_ term: String) -> GlossaryEntry? {
        allEntries.map(\.entry).first { $0.term == term }
    }
}
