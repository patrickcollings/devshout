import Testing
@testable import DevshoutCore

@Suite struct GlossaryWriterTests {
    @Test(arguments: ["sample.md", "messy.md"])
    func roundTripsFixtures(name: String) throws {
        let g = try GlossaryFixtures.glossary(name)
        let written = GlossaryWriter.markdown(g)
        #expect(GlossaryParser.parse(written) == g)
        // Writing is stable: a second pass gives the same text.
        #expect(GlossaryWriter.markdown(GlossaryParser.parse(written)) == written)
    }

    @Test func roundTripsTheStarterTemplate() {
        let g = GlossaryParser.parse(GlossaryFile.starterTemplate)
        #expect(GlossaryWriter.markdown(g) == GlossaryFile.starterTemplate)
    }

    @Test func canonicalFileIsUnchanged() {
        let text = """
        # Glossary

        ## Terms
        - !**CORSIA** — Carbon Offsetting and Reduction Scheme for International Aviation
          - heard: core sea, corsair
          - see also: ICAO
        - **procurement**

        ## People
        - **Siobhán Murphy**
          - heard: shiv on

        ## Style
        Use British English.

        """
        #expect(GlossaryWriter.markdown(GlossaryParser.parse(text)) == text)
    }

    @Test func writesAGlossaryBuiltInCode() {
        let g = Glossary(sections: [
            GlossarySection(heading: "Terms", items: [
                .entry(GlossaryEntry(term: "NDC", description: "Nationally Determined Contribution", heard: ["endy see"], pinned: true)),
            ]),
            GlossarySection(heading: "Patterns", items: [.entry(GlossaryEntry(term: "AB-{n}", heard: ["a b {n}"]))]),
        ])
        let text = GlossaryWriter.markdown(g)
        #expect(text == """
        ## Terms
        - !**NDC** — Nationally Determined Contribution
          - heard: endy see
        ## Patterns
        - **AB-{n}**
          - heard: a b {n}

        """)
        #expect(GlossaryParser.parse(text) == g)
        #expect(GlossaryWriter.markdown(.empty) == "")
    }

    @Test func inlineHeardBecomesASubBullet() {
        let g = GlossaryParser.parse("## People\n- **Siobhán Murphy** — heard: shiv on, chevonne\n")
        #expect(GlossaryWriter.markdown(g) == "## People\n- **Siobhán Murphy**\n  - heard: shiv on, chevonne\n")
    }
}
