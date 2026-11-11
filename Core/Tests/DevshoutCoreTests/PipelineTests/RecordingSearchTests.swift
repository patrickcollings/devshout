import Foundation
import Testing
@testable import DevshoutCore

@Suite struct RecordingSearchTests {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    func recording(raw: String? = nil, fixed: String? = nil, delivered: String? = nil,
                   versions: [String] = []) -> Recording {
        Recording(id: UUID(), createdAt: Self.date, rawText: raw, fixedText: fixed,
                  versions: versions.map { CleanVersion(mode: .tidy, model: "haiku", text: $0, elapsed: 1, createdAt: Self.date) },
                  deliveredText: delivered)
    }

    @Test func aBlankQueryMatchesEverything() {
        #expect(recording().matches(search: ""))
        #expect(recording(raw: "hello").matches(search: "  \n "))
    }

    @Test func looksInDeliveredCleanedAndRawText() {
        let r = recording(raw: "core sea flag", fixed: "CORSIA flag", delivered: "Check the CORSIA flag.",
                          versions: ["Check the CORSIA flag.", "- Check the flag for CORSIA eligibility"])
        #expect(r.matches(search: "sea"))          // raw only
        #expect(r.matches(search: "CORSIA flag"))  // fixed
        #expect(r.matches(search: "Check"))        // delivered
        #expect(r.matches(search: "eligibility"))  // a later version only
        #expect(!r.matches(search: "procurement"))
    }

    @Test func ignoresCaseAndAccents() {
        let r = recording(delivered: "Ask Siobhán about the Résumé")
        #expect(r.matches(search: "siobhan"))
        #expect(r.matches(search: "RESUME"))
    }

    @Test func everyWordMustAppearButNotTogether() {
        let r = recording(raw: "the flag for core sea", delivered: "The CORSIA flag")
        #expect(r.matches(search: "flag corsia"))
        #expect(r.matches(search: "corsia sea"))   // one word from each text
        #expect(!r.matches(search: "flag banana"))
    }

    @Test func aRecordingWithoutTextMatchesOnlyABlankQuery() {
        #expect(!recording().matches(search: "a"))
    }

    @Test func filteringKeepsTheOrder() {
        let a = recording(delivered: "alpha one"), b = recording(delivered: "beta"), c = recording(raw: "ALPHA two")
        #expect([a, b, c].matching(search: "alpha") == [a, c])
        #expect([a, b, c].matching(search: "") == [a, b, c])
        #expect([a, b, c].matching(search: "gamma").isEmpty)
    }
}
