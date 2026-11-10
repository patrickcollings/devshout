import Foundation
import Testing
@testable import DevshoutCore

@Suite struct TextFixerTests {
    static let sample: TextFixer = TextFixer(glossary: try! GlossaryFixtures.glossary("sample.md"))

    func fix(_ text: String, with fixer: TextFixer = TextFixerTests.sample) -> String { fixer.fix(text).text }

    @Test(arguments: [
        ("we need core sea data", "we need CORSIA data"),
        ("Core Sea is next", "CORSIA is next"),
        ("CORE SEA", "CORSIA"),
        ("core-sea", "CORSIA"),
        ("the core sea's rules", "the CORSIA's rules"),
        ("(core sea)", "(CORSIA)"),
        ("core\nsea", "CORSIA"),
        ("corsair, causia and core sea.", "CORSIA, CORSIA and CORSIA."),
        ("endy see targets", "NDC targets"),
        ("the N.D.C. target", "the NDC. target"),
        ("the n d c target", "the NDC target"),
        ("open my supplies", "open My Supply"),
        ("open mice apply now", "open My Supply now"),
    ])
    func mishearings(input: String, expected: String) {
        #expect(fix(input) == expected)
    }

    @Test(arguments: [
        "hardcore sea",
        "core seas",
        "core season",
        "écore sea",
        "core sea2",
        "core_sea",
        "corsairs",
        "encore seaside",
    ])
    func wholeWordsOnly(input: String) {
        #expect(fix(input) == input)
    }

    @Test(arguments: [
        "see https://example.com/core-sea/AB-12 for details",
        "see http://example.com/?q=core%20sea",
        "www.core-sea.com",
        "core-sea.com/path",
        "mail core.sea@example.org",
        "run `core sea` now",
        "```\ncore sea\na b 1234\n```",
        "```\nunclosed core sea",
        "file:///Users/patrick/core sea",
    ])
    func neverInsideURLsOrCode(input: String) {
        let result = Self.sample.fix(input)
        #expect(result.text == input)
        #expect(result.replacements.isEmpty)
    }

    @Test func fixesAroundProtectedText() {
        #expect(fix("core sea `core sea` core sea") == "CORSIA `core sea` CORSIA")
        #expect(fix("core sea https://x.io/core-sea") == "CORSIA https://x.io/core-sea")
    }

    @Test(arguments: [
        ("chevonne said", "Siobhán Murphy said"),
        ("Chevonne Murphy said", "Siobhán Murphy said"),
        ("ask Shiv on Murphy", "ask Siobhán Murphy"),
        ("Siobhan Murphy agreed", "Siobhán Murphy agreed"),
        ("siobhan murphy agreed", "Siobhán Murphy agreed"),
        ("Siobhán Murphy agreed", "Siobhán Murphy agreed"),
        ("Patrick Collins wrote it", "Patrick Collings wrote it"),
    ])
    func people(input: String, expected: String) {
        #expect(fix(input) == expected)
    }

    @Test func unicodeNamesAndAccents() {
        let g = GlossaryParser.parse("""
        ## People
        - **Siobhán Ní Bhriain** — heard: shiv on nee breen
        - **Zoë Ångström**
        - **Seán** — heard: shorn
        """)
        let fixer = TextFixer(glossary: g)
        #expect(fix("Shiv on nee breen and Zoe Angstrom", with: fixer) == "Siobhán Ní Bhriain and Zoë Ångström")
        #expect(fix("Zoë Ångström", with: fixer) == "Zoë Ångström")
        #expect(fix("Sean and Shorn, not Seanna", with: fixer) == "Seán and Seán, not Seanna")
        // Ranges are UTF-16 offsets into the input, even after accented and emoji text.
        let input = "Zoë 👋 said shorn"
        let r = fixer.fix(input)
        #expect(r.text == "Zoë 👋 said Seán")
        let range = try! #require(r.replacements.first?.inputRange)
        #expect((input as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count)) == "shorn")
    }

    @Test func longestMatchFirst() {
        let g = GlossaryParser.parse("""
        ## Terms
        - **Supply Hub** — heard: supplies
        - **My Supply** — heard: my supplies
        - **Core** — heard: core
        - **CORSIA** — heard: core sea
        """)
        let fixer = TextFixer(glossary: g)
        #expect(fix("my supplies and supplies", with: fixer) == "My Supply and Supply Hub")
        #expect(fix("core sea and core", with: fixer) == "CORSIA and Core")
    }

    @Test func earlierEntryWinsATie() {
        let g = GlossaryParser.parse("## Terms\n- **First** — heard: fist\n- **Second** — heard: fist\n")
        #expect(fix("a fist", with: TextFixer(glossary: g)) == "a First")
    }

    @Test func lowerCaseTermKeepsSentenceCapital() {
        let g = GlossaryParser.parse("## Terms\n- **proponent** — heard: pro ponent\n")
        let fixer = TextFixer(glossary: g)
        #expect(fix("Pro ponent is late. The pro ponent", with: fixer) == "Proponent is late. The proponent")
    }

    @Test(arguments: [
        ("see a b 1234", "see AB-1234"),
        ("see AB 1234", "see AB-1234"),
        ("see ABE 1234", "see AB-1234"),
        ("see Abe 1234", "see AB-1234"),
        ("see ab1234", "see AB-1234"),
        ("see ab-1234", "see AB-1234"),
        ("see A.B. 1234", "see AB-1234"),
        ("see AB #1234", "see AB-1234"),
        ("see a b one two three four", "see AB-1234"),
        ("see A B one, two", "see A B one, two"),
        ("see AB twelve thirty-four please", "see AB-1234 please"),
        ("see AB one hundred and five", "see AB-105"),
        ("see AB double three four", "see AB-334"),
        ("see AB 12 34", "see AB-1234"),
        ("fix AB 1234 two days ago", "fix AB-1234 two days ago"),
        ("AB 12 oh no", "AB-12 oh no"),
        ("AB 12 and AB 13.", "AB-12 and AB-13."),
        ("AB 7, then a b 8", "AB-7, then AB-8"),
        ("see AB 1", "see AB-1"),
        ("see AB twelve", "see AB-12"),
        ("see AB one two", "see AB-12"),
    ])
    func ticketPatterns(input: String, expected: String) {
        #expect(fix(input) == expected)
    }

    @Test(arguments: [
        "AB testing",
        "tab 12",
        "a b c",
        "lab 1234",
        "AB 12th",
        "ABC 1234",
        "https://linear.app/team/issue/AB-1234",
        "`AB 1234`",
        "I have 3 cats",
        "the AB one is better",
        "AB oh",
    ])
    func patternsLeaveOtherTextAlone(input: String) {
        #expect(fix(input) == input)
    }

    @Test func alreadyCorrectIsNotReported() {
        let r = Self.sample.fix("AB-1234 and CORSIA")
        #expect(r.text == "AB-1234 and CORSIA")
        #expect(r.replacements.isEmpty)
    }

    @Test func reportsReplacements() {
        let input = "core sea, then a b one two"
        let r = Self.sample.fix(input)
        #expect(r.text == "CORSIA, then AB-12")
        #expect(r.replacements == [
            TextReplacement(original: "core sea", replacement: "CORSIA", term: "CORSIA", kind: .mishearing, inputRange: 0..<8),
            TextReplacement(original: "a b one two", replacement: "AB-12", term: "AB-{n}", kind: .pattern, inputRange: 15..<26),
        ])
    }

    @Test func otherPatterns() {
        let g = GlossaryParser.parse("""
        ## Patterns
        - **PR #{n}** — pull requests
        - **v{n}.{n}** — versions
        - **{n}** — a bare number is ignored
        - **#{n}**
        """)
        let fixer = TextFixer(glossary: g)
        #expect(fix("merge PR 12 and pr number", with: fixer) == "merge PR #12 and pr number")
        #expect(fix("ship v 2 point", with: fixer) == "ship v 2 point")
        #expect(fix("ship v2 3", with: fixer) == "ship v2.3")
        #expect(fix("I have 3 cats and #4", with: fixer) == "I have 3 cats and #4")
    }

    @Test func punctuationAtTheEdgeOfAPatternKeepsTheSpacesAroundIt() {
        let g = GlossaryParser.parse("## Patterns\n- **#{n}**\n- **{n}%**\n- **(v{n})**\n")
        let fixer = TextFixer(glossary: g)
        for text in ["Fixed it, #12 is done.", "Done. #12", "about 12% more.", "a (v2) b", "x #12, y"] {
            let r = fixer.fix(text)
            #expect(r.text == text)
            #expect(r.replacements.isEmpty)
        }
        #expect(fix("Fixed it, # 12 is done.", with: fixer) == "Fixed it, #12 is done.")
        #expect(fix("about 12 % more", with: fixer) == "about 12% more")
        #expect(fix("a ( v 2 ) b", with: fixer) == "a (v2) b")
    }

    @Test func emptyAndStarterGlossariesChangeNothing() {
        let text = "core sea a b 1234 Siobhan"
        #expect(TextFixer(glossary: .empty).isEmpty)
        #expect(TextFixer(glossary: .empty).fix(text) == TextFixResult(text: text, replacements: []))
        #expect(TextFixer(glossary: GlossaryParser.parse(GlossaryFile.starterTemplate)).fix(text).text == text)
        #expect(Self.sample.fix("").text == "")
    }

    @Test func oddHeardPhrasesDontBreakAnything() {
        let g = GlossaryParser.parse("""
        ## Terms
        - **C++** — heard: c plus plus, (x), [y], a.*b, \\d+
        - **Dot** — heard: ., -
        """)
        let fixer = TextFixer(glossary: g)
        #expect(fix("I like c plus plus", with: fixer) == "I like C++")
        #expect(fix("aXXb 123 (x)", with: fixer) == "aXXb 123 C++")
        #expect(fix("a.*b and \\d+", with: fixer) == "C++ and C++")
        #expect(fix("The end. A-ha", with: fixer) == "The end. A-ha")
    }
}
