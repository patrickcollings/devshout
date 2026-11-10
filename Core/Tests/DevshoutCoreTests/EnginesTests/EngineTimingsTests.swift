import Foundation
import Testing
@testable import DevshoutCore

@Suite struct EngineTimingsTests {
    @Test func offsetOfChunk() {
        let chunk = AudioChunk(index: 3, startSample: 48_000, endSample: 64_000, samples: [])
        #expect(EngineTimings.offsetSeconds(of: chunk) == 3)
    }

    @Test func mergesSubwordTokensFromFluidAudio() {
        // FluidAudio replaces ▁ with a space in tokenTimings.
        let tokens = [
            RawTiming(text: " My", start: 0.00, end: 0.16),
            RawTiming(text: " Sup", start: 0.24, end: 0.40),
            RawTiming(text: "ply", start: 0.40, end: 0.56),
            RawTiming(text: " works", start: 0.64, end: 0.96),
            RawTiming(text: ".", start: 0.96, end: 1.04),
        ]
        let words = EngineTimings.mergeSubwordTokens(tokens, offset: 10)
        #expect(words.map(\.text) == ["My", "Supply", "works."])
        #expect(words[1].start == 10.24)
        #expect(words[1].end == 10.56)
        #expect(words[2].end == 11.04)
    }

    @Test func mergesRawSentencePieceMarkers() {
        let tokens = [
            RawTiming(text: "\u{2581}AB", start: 0, end: 0.1),
            RawTiming(text: "-", start: 0.1, end: 0.2),
            RawTiming(text: "12", start: 0.2, end: 0.3),
            RawTiming(text: "34", start: 0.3, end: 0.4),
            RawTiming(text: "\u{2581}", start: 0.4, end: 0.45),
            RawTiming(text: "done", start: 0.5, end: 0.7),
        ]
        let words = EngineTimings.mergeSubwordTokens(tokens)
        #expect(words.map(\.text) == ["AB-1234", "done"])
        #expect(words[1].start == 0.5)
    }

    @Test func firstTokenWithoutSpaceStartsAWord() {
        let words = EngineTimings.mergeSubwordTokens([
            RawTiming(text: "Hel", start: 0, end: 0.1),
            RawTiming(text: "lo", start: 0.1, end: 0.2),
        ])
        #expect(words == [TimedWord(text: "Hello", start: 0, end: 0.2)])
    }

    @Test func dropsSpecialTokens() {
        let words = EngineTimings.mergeSubwordTokens([
            RawTiming(text: "<blank>", start: 0, end: 0.1),
            RawTiming(text: " hi", start: 0.1, end: 0.2),
            RawTiming(text: "<unk>", start: 0.2, end: 0.3),
            RawTiming(text: "<|endoftext|>", start: 0.3, end: 0.3),
        ])
        #expect(words.map(\.text) == ["hi"])
    }

    @Test func endNeverBeforeStart() {
        let words = EngineTimings.mergeSubwordTokens([RawTiming(text: " x", start: 2, end: 1)])
        #expect(words[0].end >= words[0].start)
        let whisper = EngineTimings.words(from: [RawTiming(text: " y", start: 2, end: 1.5)], offset: 1)
        #expect(whisper == [TimedWord(text: "y", start: 3, end: 3)])
    }

    @Test func emptyInputGivesNoWords() {
        #expect(EngineTimings.mergeSubwordTokens([]).isEmpty)
        #expect(EngineTimings.words(from: []).isEmpty)
    }

    @Test func whisperWordsAreTrimmedAndOffset() {
        let timings = [
            RawTiming(text: " Siobhán", start: 0.0, end: 0.5),
            RawTiming(text: " said", start: 0.5, end: 0.8),
            RawTiming(text: "<|0.80|>", start: 0.8, end: 0.8),
            RawTiming(text: "  ", start: 0.8, end: 0.9),
            RawTiming(text: " CORSIA.", start: 0.9, end: 1.4),
        ]
        let words = EngineTimings.words(from: timings, offset: 28)
        #expect(words.map(\.text) == ["Siobhán", "said", "CORSIA."])
        #expect(words[0].start == 28)
        #expect(words[2].end == 29.4)
    }
}

@Suite struct TranscriptTextTests {
    @Test func stripsWhisperSpecialTokens() {
        let raw = "<|startoftranscript|><|en|><|transcribe|><|0.00|> Hello there.<|2.40|><|endoftext|>"
        #expect(TranscriptText.normalise(raw) == "Hello there.")
    }

    @Test func keepsTextBetweenTokens() {
        #expect(TranscriptText.normalise("one<|1.00|>two") == "one two")
    }

    @Test func leavesUnclosedMarkerAlone() {
        #expect(TranscriptText.normalise("a <| b") == "a <| b")
    }

    @Test func collapsesWhitespaceButKeepsCasingAndPunctuation() {
        #expect(TranscriptText.normalise("  So,   the NDC\n is   fine ") == "So, the NDC is fine")
    }

    @Test func detectsPromptEcho() {
        let prompt = "CORSIA, NDC, My Supply, Siobhán Murphy, procurement, proponent"
        #expect(TranscriptText.isPromptEcho("CORSIA NDC my supply Siobhán", prompt: prompt))
        #expect(!TranscriptText.isPromptEcho("CORSIA", prompt: prompt))  // too short to call it an echo
        #expect(!TranscriptText.isPromptEcho("CORSIA is my supply for this", prompt: prompt))
        #expect(!TranscriptText.isPromptEcho("anything at all here", prompt: nil))
    }
}

@Suite struct EngineAudioTests {
    @Test func padsShortAudio() {
        let padded = EngineAudio.padded([0.5, 0.5], toAtLeast: 5)
        #expect(padded == [0.5, 0.5, 0, 0, 0])
        #expect(EngineAudio.padded([1, 2, 3], toAtLeast: 2) == [1, 2, 3])
    }

    @Test func silence() {
        #expect(EngineAudio.isSilent([0, 0, 0.00001]))
        #expect(!EngineAudio.isSilent([0, 0.2]))
    }
}
