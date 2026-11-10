import Testing
@testable import DevshoutCore

@Suite struct GlossaryRendererTests {
    @Test func rendersThePlanExampleForClaude() throws {
        let g = try GlossaryFixtures.glossary("sample.md")
        let expected = try GlossaryFixtures.text("sample.claude.txt")
        #expect(GlossaryRenderer.forClaude(g) + "\n" == expected)
    }

    @Test func keepsUnknownLinesAndOtherSectionsButNotComments() throws {
        let out = GlossaryRenderer.forClaude(try GlossaryFixtures.glossary("messy.md"))
        #expect(out.hasPrefix("Some text before any heading.\n\nTerms (correct spelling — meaning — misheard as):\n"))
        #expect(!out.contains("# Our glossary"))
        #expect(!out.contains("Hidden"))
        #expect(!out.contains("<!--"))
        #expect(out.contains("- ITMO — Internationally Transferred Mitigation Outcome — heard: it mo, item o\n"))
        #expect(out.contains("- Baseline — the counterfactual — see also: additionality; continuation without a bullet — heard: base line\n"))
        #expect(out.contains("This line is just prose in the middle of the terms.\n"))
        #expect(out.contains("- Verra — registry\n"))
        #expect(out.contains("Patterns ({n} stands for a number):\n- AB-{n} — Linear tickets — heard: ABE {n}\n- PR #{n} — pull requests"))
        #expect(out.contains("Style:\nUse British English.\n\nPrefer \"carbon credits\" to \"offsets\".\n\n"))
        #expect(out.hasSuffix("Notes for Claude:\n- The team sometimes says \"the platform\" for My Supply.\n### A sub-heading"))
        #expect(!out.contains("\n\n\n"))
    }

    @Test func emptyGlossaries() {
        #expect(GlossaryRenderer.forClaude(.empty) == "")
        #expect(GlossaryRenderer.forClaude(GlossaryParser.parse(GlossaryFile.starterTemplate)) == "")
        #expect(GlossaryRenderer.forClaude(GlossaryParser.parse("## Terms\n\n## People\n")) == "")
    }

    @Test func entryLine() {
        #expect(GlossaryRenderer.line(for: GlossaryEntry(term: "X")) == "- X")
        #expect(GlossaryRenderer.line(for: GlossaryEntry(term: "X", description: "d", heard: ["a", "b"], pinned: true, notes: ["n"]))
            == "- X — d — n — heard: a, b")
    }
}
