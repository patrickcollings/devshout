import Foundation
import Testing
@testable import DevshoutCore

@Suite struct TidyLengthCheckTests {
    let raw = "so um I think we should uh move the meeting to Tuesday no I mean Wednesday because the client cannot do Tuesday afternoon at all"

    @Test func tidiedTextPasses() {
        let tidied = "I think we should move the meeting to Wednesday, because the client can't do Tuesday afternoon at all."
        #expect(TidyLengthCheck.failureReason(raw: raw, output: tidied) == nil)
    }

    @Test func summaryFails() throws {
        let reason = try #require(TidyLengthCheck.failureReason(raw: raw, output: "Move the meeting to Wednesday."))
        #expect(reason.contains("shorter"))
    }

    @Test func answerFails() throws {
        let essay = String(repeating: "Here is a thorough answer to your question about meetings. ", count: 5)
        let reason = try #require(TidyLengthCheck.failureReason(raw: raw, output: essay))
        #expect(reason.contains("longer"))
    }

    @Test func shortDictationsGetSlack() {
        #expect(TidyLengthCheck.failureReason(raw: "um yes okay", output: "Yes.") == nil)
        #expect(TidyLengthCheck.failureReason(raw: "what is two plus two", output: "Four.") != nil)
    }

    @Test func boundaries() {
        let ten = Array(repeating: "word", count: 10).joined(separator: " ")
        let seven = Array(repeating: "word", count: 7).joined(separator: " ")
        let six = Array(repeating: "word", count: 6).joined(separator: " ")
        let thirteen = Array(repeating: "word", count: 13).joined(separator: " ")
        let fourteen = Array(repeating: "word", count: 14).joined(separator: " ")
        #expect(TidyLengthCheck.failureReason(raw: ten, output: seven) == nil)
        #expect(TidyLengthCheck.failureReason(raw: ten, output: thirteen) == nil)
        #expect(TidyLengthCheck.failureReason(raw: ten, output: six) != nil)
        #expect(TidyLengthCheck.failureReason(raw: ten, output: fourteen) != nil)
    }

    @Test func wordCountIgnoresPunctuationOnlyTokens() {
        #expect(TidyLengthCheck.wordCount("- one — two\n\n* three 4") == 4)
    }
}

@Suite struct CoverageCheckTests {
    let raw = """
        okay so the goal is to fix AB-1234 and also ab-99 where the CORSIA total is off by 20% \
        it's in Core/Sources/Glossary/Parser.swift and maybe PLAN.md and the limit should be 1,000 \
        not 500 and keep my supply working and/or the proponent page
        """
    let terms = ["CORSIA", "My Supply", "proponent", "NDC"]

    @Test func everythingKept() {
        let output = """
            # Goal
            Fix AB-1234 and AB-99: the CORSIA total is off by 20 per cent... no, 20%.
            1. Look in `Core/Sources/Glossary/Parser.swift` and `PLAN.md`.
            2. Set the limit to 1000, not 500.
            3. Keep My Supply and the proponent page working.
            """
        #expect(CoverageCheck.missingItems(raw: raw, output: output, glossaryTerms: terms) == [])
        #expect(CoverageCheck.warnings(raw: raw, output: output, glossaryTerms: terms) == [])
    }

    @Test func reportsWhatWasDropped() {
        let output = "# Goal\nFix the CORSIA total in Parser.swift. Keep the limit at 1,000."
        #expect(CoverageCheck.missingItems(raw: raw, output: output, glossaryTerms: terms) == [
            "AB-1234", "ab-99", "Core/Sources/Glossary/Parser.swift", "PLAN.md", "20%", "500", "My Supply", "proponent",
        ])
        #expect(CoverageCheck.warnings(raw: raw, output: output, glossaryTerms: terms) == [
            "may have dropped: AB-1234, ab-99, Core/Sources/Glossary/Parser.swift, PLAN.md, 20%, 500, My Supply, proponent",
        ])
    }

    @Test func termsNotSaidAreNotExpected() {
        #expect(CoverageCheck.missingItems(raw: "nothing special here", output: "Nothing special.",
                                           glossaryTerms: terms) == [])
    }

    @Test func termsMatchWholeWordsOnly() {
        #expect(CoverageCheck.missingItems(raw: "the NDCs are due", output: "The submissions are due.",
                                           glossaryTerms: ["NDC"]) == [])
    }

    @Test func digitsInsideIDsAreNotCountedAsNumbers() {
        #expect(CoverageCheck.missingItems(raw: "close AB-1234", output: "Close AB-1234.") == [])
    }

    @Test func pathsAreRecognised() {
        let text = "edit ~/.zshrc and ./scripts/build.sh and /usr/local/bin and docs/PLAN.md and README.md and/or input/output"
        #expect(CoverageCheck.filePaths(in: text) == [
            "~/.zshrc", "./scripts/build.sh", "/usr/local/bin", "docs/PLAN.md", "README.md",
        ])
    }

    @Test func glossaryTermsFromMarkdown() throws {
        let glossary = try ClaudeTestSupport.fixture("glossary.md")
        #expect(CoverageCheck.glossaryTerms(in: glossary) == [
            "CORSIA", "NDC", "My Supply", "proponent", "Siobhán Murphy",
        ])
    }
}
