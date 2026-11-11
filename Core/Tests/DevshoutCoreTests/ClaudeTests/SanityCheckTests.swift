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

    /// "w0 w1 … " with distinct words, so nothing counts as a repeat.
    func numbered(_ range: Range<Int>) -> String { range.map { "word\($0)" }.joined(separator: " ") }

    @Test func boundaries() {
        let twenty = numbered(0..<20)
        // 70% and over: the length is enough, wherever the output stops.
        #expect(TidyLengthCheck.failureReason(raw: twenty, output: numbered(0..<14)) == nil)
        // 50–70%: only when it still reaches the end.
        #expect(TidyLengthCheck.failureReason(raw: twenty, output: numbered(0..<5) + " " + numbered(12..<20)) == nil)
        #expect(TidyLengthCheck.failureReason(raw: twenty, output: numbered(10..<20)) == nil)
        let cutOff = try? #require(TidyLengthCheck.failureReason(raw: twenty, output: numbered(0..<13)))
        #expect(cutOff?.contains("cut off") == true)
        // Under 50%: never.
        let summary = try? #require(TidyLengthCheck.failureReason(raw: twenty, output: numbered(11..<20)))
        #expect(summary?.contains("summarised") == true)
        // Up to 130%.
        #expect(TidyLengthCheck.failureReason(raw: twenty, output: numbered(0..<26)) == nil)
        #expect(TidyLengthCheck.failureReason(raw: twenty, output: numbered(0..<27))?.contains("longer") == true)
    }

    /// A real ramble: fillers, stammers, restarts and self-corrections. 97 words, 88 without fillers and stammers.
    let ramble = """
        okay so um what I what I wanted to say is that the the procurement page um it loads really slowly no not \
        slowly it it times out when you open it from the from the dashboard and uh I think I think the problem is \
        the supplier query no sorry the project query because it it joins every every credit so can you um can you \
        add an index on the project id or no wait first check the query plan and then add the index and uh tell me \
        how long it takes after that
        """

    @Test func aRamblingDictationCanShrinkALot() {
        // Everything said is still there; only what Tidy is told to remove has gone. 46 words: 47% of the raw
        // words (the old 70% rule rejected it and the ramble was pasted instead) and 52% of the non-filler ones.
        let tidied = """
            The procurement page times out when you open it from the dashboard. I think the problem is the project \
            query, because it joins every credit. Can you first check the query plan and then add the index, and tell \
            me how long it takes after that?
            """
        #expect(TidyLengthCheck.wordCount(ramble) == 97)
        #expect(TidyLengthCheck.contentWordCount(ramble) == 88)
        #expect(TidyLengthCheck.wordCount(tidied) == 46)
        #expect(TidyLengthCheck.failureReason(raw: ramble, output: tidied) == nil)
    }

    @Test func aRambleCutOffPartWayIsStillCaught() throws {
        // The same length as the good result, but it is the first part of the dictation, lightly tidied.
        let cutOff = """
            What I wanted to say is that the procurement page loads really slowly, no, not slowly, it times out when \
            you open it from the dashboard. I think the problem is the supplier query, no sorry, the project query, \
            because it joins every credit, so can
            """
        #expect(TidyLengthCheck.wordCount(cutOff) == 46)
        let reason = try #require(TidyLengthCheck.failureReason(raw: ramble, output: cutOff))
        #expect(reason.contains("cut off"))
        #expect(reason.contains("46 words from 97"))
    }

    @Test func aSummaryOfARambleIsStillCaught() throws {
        let summary = "The procurement page times out because of the project query. Check the query plan, add an index on the project id and report the timing."
        let reason = try #require(TidyLengthCheck.failureReason(raw: ramble, output: summary))
        #expect(reason.contains("summarised"))
    }

    @Test func fillersAndStammersAreNotCounted() {
        #expect(TidyLengthCheck.contentWordCount("um, so the the plan is, uh, like, simple. Erm... yes yes yes") == 7)
        // Not fillers: real words that happen to repeat further apart, and "like" or "you know".
        #expect(TidyLengthCheck.contentWordCount("I like it, you know, I like it") == 8)
        #expect(TidyLengthCheck.contentWordCount("") == 0)
    }

    @Test func reachingTheEnd() {
        let raw = "please move the meeting with the client to Tuesday afternoon no sorry I mean Wednesday morning"
        #expect(TidyLengthCheck.reachesTheEnd(raw: raw, output: "Please move the client meeting to Wednesday morning."))
        #expect(!TidyLengthCheck.reachesTheEnd(raw: raw, output: "Please move the meeting with the client"))
        // Too few distinctive words to judge.
        #expect(TidyLengthCheck.reachesTheEnd(raw: "so it is to be or not", output: "anything"))
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

    /// What the session really passes: the glossary as rendered for Claude.
    @Test func glossaryTermsFromTheClaudeRendering() throws {
        let rendered = GlossaryRenderer.forClaude(GlossaryParser.parse(try ClaudeTestSupport.fixture("glossary.md")))
        #expect(!rendered.contains("**"))
        #expect(CoverageCheck.glossaryTerms(in: rendered) == [
            "CORSIA", "NDC", "My Supply", "proponent", "Siobhán Murphy",
        ])
        let raw = "the core sea number for my supply is wrong"
        #expect(CoverageCheck.warnings(raw: raw, output: "The CORSIA number is wrong.",
                                       glossaryTerms: CoverageCheck.glossaryTerms(in: rendered))
                == ["may have dropped: My Supply"])
    }

    @Test func glossaryTermsFromPlainBullets() {
        #expect(CoverageCheck.glossaryTerms(in: "## Terms\n- CORSIA\n- NDC — contribution\n  - heard: endy see\n## Style\n- Use British English.")
                == ["CORSIA", "NDC"])
    }

    @Test func glossaryTermsFromMarkdown() throws {
        let glossary = try ClaudeTestSupport.fixture("glossary.md")
        #expect(CoverageCheck.glossaryTerms(in: glossary) == [
            "CORSIA", "NDC", "My Supply", "proponent", "Siobhán Murphy",
        ])
    }
}
