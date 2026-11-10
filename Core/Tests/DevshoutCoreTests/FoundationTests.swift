import Testing
@testable import DevshoutCore

@Suite struct FoundationTests {
    @Test func modeDefaults() {
        #expect(ModeConfig.defaults[.tidy]?.claudeModel == "haiku")
        #expect(ModeConfig.defaults[.structure]?.claudeModel == "sonnet")
        #expect(!ModeID.raw.usesClaude)
    }

    @Test func chunkDuration() {
        let chunk = AudioChunk(index: 0, startSample: 0, endSample: 32_000, samples: [])
        #expect(chunk.duration == 2)
    }
}
