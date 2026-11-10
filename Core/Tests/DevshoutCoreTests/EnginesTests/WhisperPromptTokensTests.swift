import Testing
@testable import DevshoutCore

@Suite struct WhisperPromptTokensTests {
    @Test func limits() {
        #expect(WhisperPromptTokens.maxPromptTokens == 224)
        #expect(WhisperPromptTokens.maxContentTokens == 223)
    }

    @Test func shortPartsAreKeptWhole() {
        let tokens = WhisperPromptTokens.assemble(vocabulary: [1, 2, 3], previous: [7, 8])
        #expect(tokens == [1, 2, 3, 7, 8])
    }

    @Test func vocabularyIsCutFromTheEndAndPreviousFromTheStart() {
        let vocabulary = Array(1...300)
        let previous = Array(1001...1100)
        let tokens = WhisperPromptTokens.assemble(vocabulary: vocabulary, previous: previous)
        #expect(tokens.count == 223)
        // Previous text gets its 40-token budget: its last 40 tokens.
        #expect(Array(tokens.suffix(40)) == Array(1061...1100))
        // Vocabulary keeps its first 183 tokens.
        #expect(Array(tokens.prefix(183)) == Array(1...183))
    }

    @Test func previousTextUsesSpareRoom() {
        let tokens = WhisperPromptTokens.assemble(vocabulary: Array(1...10), previous: Array(1001...1300))
        #expect(tokens.count == 223)
        #expect(Array(tokens.prefix(10)) == Array(1...10))
        #expect(tokens.last == 1300)
        #expect(tokens[10] == 1300 - 213 + 1)
    }

    @Test func noVocabulary() {
        let tokens = WhisperPromptTokens.assemble(vocabulary: [], previous: Array(1...500))
        #expect(tokens == Array(278...500))
    }

    @Test func nothingAtAll() {
        #expect(WhisperPromptTokens.assemble(vocabulary: [], previous: []).isEmpty)
        #expect(WhisperPromptTokens.assemble(vocabulary: [1], previous: [2], maxContent: 0).isEmpty)
    }

    @Test func tinyCap() {
        let tokens = WhisperPromptTokens.assemble(vocabulary: [1, 2, 3], previous: [7, 8, 9], maxContent: 2, previousBudget: 40)
        #expect(tokens == [8, 9])
    }

    @Test func neverExceedsCapForAnySizes() {
        for v in [0, 1, 100, 183, 184, 223, 400] {
            for p in [0, 1, 39, 40, 41, 223, 400] {
                let tokens = WhisperPromptTokens.assemble(vocabulary: Array(repeating: 1, count: v),
                                                          previous: Array(repeating: 2, count: p))
                #expect(tokens.count <= 223)
                #expect(tokens.count == min(223, v + p))
            }
        }
    }

    @Test func promptText() {
        #expect(WhisperPromptTokens.promptText(nil) == nil)
        #expect(WhisperPromptTokens.promptText("   ") == nil)
        #expect(WhisperPromptTokens.promptText(" CORSIA,  NDC ") == " CORSIA, NDC")
    }
}
