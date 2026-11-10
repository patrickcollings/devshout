import Testing
@testable import DevshoutCore

@Suite struct WhisperPromptBuilderTests {
    static let glossary = GlossaryParser.parse("""
    ## Terms
    - **CORSIA**
    - **NDC**
    - !**My Supply**
    - **procurement**
    ## People
    - **Siobhán Murphy**
    - **ndc**
    ## Patterns
    - !**AB-{n}**
    - **Verra**
    ## Terms
    - **proponent**
    """)

    @Test func ordersPinnedThenPeopleThenTerms() {
        #expect(WhisperPromptBuilder.candidates(Self.glossary)
            == ["My Supply", "Siobhán Murphy", "ndc", "CORSIA", "procurement", "proponent"])
        // Patterns are never sent (and "NDC" is the same term as "ndc", which came first).
    }

    @Test func fitsEverythingWithARoomyBudget() {
        let v = WhisperPromptBuilder(tokenCounter: CharacterTokenCounter(), glossaryBudget: 1_000).vocabulary(for: Self.glossary)
        #expect(v.prompt == "My Supply, Siobhán Murphy, ndc, CORSIA, procurement, proponent")
        #expect(v.includedCount == 6)
        #expect(v.candidateCount == 6)
        #expect(v.tokenCount == v.prompt.count)
        #expect(v.summary == "Whisper sees 6 of 6 terms (\(v.prompt.count)/1000 tokens)")
    }

    @Test func stopsAtTheBudget() {
        // "My Supply, Siobhán Murphy" is 25 characters; adding ", ndc" makes 30.
        for (budget, expected) in [(0, 0), (8, 0), (9, 1), (24, 1), (25, 2), (29, 2), (30, 3)] {
            let v = WhisperPromptBuilder(tokenCounter: CharacterTokenCounter(), glossaryBudget: budget).vocabulary(for: Self.glossary)
            #expect(v.includedCount == expected, "budget \(budget)")
            #expect(v.tokenCount <= budget)
            #expect(v.prompt.count == v.tokenCount)
        }
    }

    @Test func keepsFileOrderRatherThanSkippingAhead() {
        let g = GlossaryParser.parse("## Terms\n- **A**\n- **A very long term indeed**\n- **B**\n")
        let v = WhisperPromptBuilder(tokenCounter: CharacterTokenCounter(), glossaryBudget: 10).vocabulary(for: g)
        #expect(v.includedTerms == ["A"])
        #expect(v.summary == "Whisper sees 1 of 3 terms (1/10 tokens)")
    }

    @Test func defaultBudgetWithTheApproximateCounter() {
        let entries = (1...300).map { "- **Term number \($0)**" }.joined(separator: "\n")
        let g = GlossaryParser.parse("## Terms\n" + entries)
        let builder = WhisperPromptBuilder()
        #expect(builder.glossaryBudget == 180)
        #expect(builder.previousTextBudget == 40)
        let v = builder.vocabulary(for: g)
        #expect(v.tokenCount <= 180)
        #expect(v.tokenCount > 160)
        #expect(ApproximateTokenCounter().count(v.prompt) == v.tokenCount)
        #expect(v.includedCount > 10 && v.includedCount < 300)
        #expect(v.includedTerms.first == "Term number 1")
    }

    @Test func emptyGlossary() {
        let v = WhisperPromptBuilder().vocabulary(for: .empty)
        #expect(v.prompt == "")
        #expect(v.summary == "Whisper sees 0 of 0 terms (0/180 tokens)")
        #expect(WhisperPromptBuilder().context(glossary: .empty).vocabularyPrompt == nil)
    }

    @Test func previousTextTail() {
        let b = WhisperPromptBuilder(tokenCounter: WordTokenCounter(), previousTextBudget: 3)
        #expect(b.previousTextTail("one two three four five") == "three four five")
        #expect(b.previousTextTail("  one\ntwo  ") == "one two")
        #expect(b.previousTextTail("") == nil)
        #expect(b.previousTextTail(nil) == nil)
        let tight = WhisperPromptBuilder(tokenCounter: CharacterTokenCounter(), previousTextBudget: 4)
        #expect(tight.previousTextTail("a supercalifragilistic") == nil)
        #expect(tight.previousTextTail("it was ok") == "ok")
    }

    @Test func contextForAChunk() {
        let b = WhisperPromptBuilder(tokenCounter: CharacterTokenCounter(), glossaryBudget: 9, previousTextBudget: 5)
        let c = b.context(glossary: Self.glossary, previousText: "and then we said hello")
        #expect(c == TranscriptionContext(language: "en", vocabularyPrompt: "My Supply", previousText: "hello"))
    }
}
