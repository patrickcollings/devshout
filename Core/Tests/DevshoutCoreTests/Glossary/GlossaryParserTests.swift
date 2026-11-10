import Testing
@testable import DevshoutCore

@Suite struct GlossaryParserTests {
    @Test func parsesThePlanExample() throws {
        let g = try GlossaryFixtures.glossary("sample.md")
        #expect(g.title == "Abatable glossary")
        #expect(g.sections.map(\.kind) == [.other, .terms, .people, .patterns, .style])
        #expect(g.terms.map(\.term) == ["CORSIA", "NDC", "My Supply", "proponent", "procurement"])
        #expect(g.entry("CORSIA") == GlossaryEntry(
            term: "CORSIA", description: "Carbon Offsetting and Reduction Scheme for International Aviation",
            heard: ["core sea", "corsair", "causia"]))
        #expect(g.entry("My Supply")?.description == "Abatable product: a buyer's supply of credits")
        #expect(g.entry("procurement") == GlossaryEntry(term: "procurement"))
        #expect(g.people == [
            GlossaryEntry(term: "Siobhán Murphy", heard: ["shiv on", "chevonne"]),
            GlossaryEntry(term: "Patrick Collings", heard: ["Patrick Collins"]),
        ])
        #expect(g.patterns == [GlossaryEntry(term: "AB-{n}", description: "Linear ticket IDs",
                                             heard: ["a b {n}", "AB {n}", "ABE {n}"])])
        #expect(g.styleText == "- Use British English. Write \"My Supply\" with both words capitalised.")
        #expect(g.countsSummary == "5 terms, 2 people, 1 pattern")
    }

    @Test func handWrittenVariations() throws {
        let g = try GlossaryFixtures.glossary("messy.md")
        #expect(g.title == "Our glossary")
        #expect(g.sections.map(\.kind) == [.other, .terms, .people, .patterns, .style, .other])
        #expect(g.sections.map(\.heading) == [nil, "terms:", "PEOPLE", "Ticket patterns", "Style", "Notes for Claude"])

        #expect(g.entry("Article 6")?.description == "the Paris Agreement article on carbon markets")
        #expect(g.entry("ITMO") == GlossaryEntry(term: "ITMO", description: "Internationally Transferred Mitigation Outcome",
                                                 heard: ["it mo", "item o"]))
        #expect(g.entry("Verra") == GlossaryEntry(term: "Verra", description: "registry", pinned: true))
        #expect(g.entry("Gold Standard") == GlossaryEntry(term: "Gold Standard", pinned: true))
        #expect(g.entry("Sylvera") == GlossaryEntry(term: "Sylvera", description: "ratings agency", pinned: true))
        #expect(g.entry("Plain Term")?.description == "with a description")
        #expect(g.entry("NDC") == GlossaryEntry(term: "NDC", description: "Nationally Determined Contribution",
                                                heard: ["N D C", "endy see"]))
        #expect(g.entry("BeZero") == GlossaryEntry(term: "BeZero"))
        #expect(g.entry("Visible")?.description == "shown here")
        #expect(g.entry("Hidden") == nil)

        let baselines = g.terms.filter { $0.term == "Baseline" }
        #expect(baselines == [
            GlossaryEntry(term: "Baseline", description: "the counterfactual", heard: ["base line"],
                          notes: ["see also: additionality", "continuation without a bullet"]),
            GlossaryEntry(term: "Baseline", description: "duplicate entry", heard: ["bass line"]),
        ])

        #expect(g.people.map(\.term) == ["Siobhán Ní Bhriain", "Zoë Ångström"])
        #expect(g.entry("Siobhán Ní Bhriain")?.heard == ["shiv on nee breen"])
        #expect(g.patterns.map(\.term) == ["AB-{n}", "PR #{n}"])
        #expect(g.styleText == "Use British English.\n\nPrefer \"carbon credits\" to \"offsets\".")
    }

    @Test func unknownLinesAreKeptAsNotes() throws {
        let g = try GlossaryFixtures.glossary("messy.md")
        let termNotes = g.sections[1].notes.map(\.text).filter { !$0.isEmpty }
        #expect(termNotes == [
            "- **Unclosed bold — oops",
            "- heard: orphan mishearing",
            "This line is just prose in the middle of the terms.",
            "  - an indented line with no entry above it",
            "- This bullet is a long sentence that is clearly not a glossary term at all",
        ])
        // The commented-out entry is kept as raw text but is invisible.
        #expect(g.sections[1].notes.contains { $0.raw.contains("Hidden") && $0.text.isEmpty })
        #expect(g.sections[0].notes.first?.text == "Some text before any heading.")
        #expect(g.sections[5].notes.map(\.text) == ["- The team sometimes says \"the platform\" for My Supply.", "### A sub-heading"])
    }

    @Test(arguments: [
        "- **CORSIA** — Carbon scheme",
        "- **CORSIA** – Carbon scheme",
        "- **CORSIA** - Carbon scheme",
        "- **CORSIA**: Carbon scheme",
        "- **CORSIA:** Carbon scheme",
        "- **CORSIA** Carbon scheme",
        "- CORSIA — Carbon scheme",
        "- CORSIA - Carbon scheme",
        "- CORSIA: Carbon scheme",
        "- CORSIA—Carbon scheme",
        "* __CORSIA__ — Carbon scheme",
        "+ **CORSIA** — Carbon scheme",
        "• **CORSIA** — Carbon scheme",
        " - **CORSIA**   —   Carbon scheme  ",
    ])
    func separators(line: String) {
        let g = GlossaryParser.parse("## Terms\n\(line)\n")
        #expect(g.terms == [GlossaryEntry(term: "CORSIA", description: "Carbon scheme")])
    }

    @Test(arguments: [
        "- **CORSIA** — Carbon scheme — heard: core sea, corsair",
        "- **CORSIA** — Carbon scheme (heard: core sea, corsair)",
        "- **CORSIA** — Carbon scheme; heard: core sea; corsair",
        "- **CORSIA** — Carbon scheme — Heard as: “core sea”, 'corsair'",
        "- **CORSIA** — Carbon scheme\n  - heard: core sea\n  - heard: corsair, Core Sea",
        "- **CORSIA** — Carbon scheme\n\t* misheard: core sea, corsair.",
        "- CORSIA — Carbon scheme — heard: core sea, corsair",
    ])
    func heardForms(text: String) {
        let g = GlossaryParser.parse("## Terms\n\(text)\n")
        #expect(g.terms == [GlossaryEntry(term: "CORSIA", description: "Carbon scheme", heard: ["core sea", "corsair"])])
    }

    @Test(arguments: [
        "- **CORSIA** (heard: core sea, corsair) — Carbon scheme",
        "- **CORSIA** [heard: core sea, corsair] Carbon scheme",
        "- CORSIA (heard: core sea; corsair): Carbon scheme",
    ])
    func bracketedHeardBeforeTheDescription(line: String) {
        let g = GlossaryParser.parse("## Terms\n\(line)\n")
        #expect(g.terms == [GlossaryEntry(term: "CORSIA", description: "Carbon scheme", heard: ["core sea", "corsair"])])
    }

    @Test func bracketedHeardInTheMiddleOfTheDescription() {
        let g = GlossaryParser.parse("## Terms\n- **CORSIA** — Carbon (heard: core sea) scheme\n")
        #expect(g.terms == [GlossaryEntry(term: "CORSIA", description: "Carbon scheme", heard: ["core sea"])])
    }

    @Test func inlineHeardWithoutDescription() {
        let g = GlossaryParser.parse("## People\n- **Siobhán Murphy** — heard: shiv on\n- Patrick: heard: Patrick Collins\n")
        #expect(g.people == [
            GlossaryEntry(term: "Siobhán Murphy", heard: ["shiv on"]),
            GlossaryEntry(term: "Patrick", heard: ["Patrick Collins"]),
        ])
    }

    @Test func pins() {
        let g = GlossaryParser.parse("""
        ## Terms
        - !**A**
        - ! **B** — b
        - **!C**
        - !D — d
        - **E**
        """)
        #expect(g.terms.map(\.pinned) == [true, true, true, true, false])
        #expect(g.terms.map(\.term) == ["A", "B", "C", "D", "E"])
    }

    @Test func patternsAndPlaceholders() {
        let g = GlossaryParser.parse("## Patterns\n- **AB-{n}** — tickets\n  - heard: a b {n}\n- AB-{n}-{n}\n- Not a pattern\n")
        #expect(g.patterns.map(\.term) == ["AB-{n}", "AB-{n}-{n}"])
        #expect(g.entries(in: .patterns).count == 3)
        #expect(g.entry("AB-{n}")?.isPattern == true)
    }

    @Test func multiLineCommentsHideEntries() {
        let g = GlossaryParser.parse("""
        ## Terms
        <!--
        - **Hidden** — hidden
        -->
        - **Shown** <!-- inline --> — yes <!-- and
        more comment --> 
        - **Also shown**
        """)
        #expect(g.terms.map(\.term) == ["Shown", "Also shown"])
        #expect(g.entry("Shown")?.description == "yes")
    }

    @Test func lineEndingsAndBOM() {
        let g = GlossaryParser.parse("\u{FEFF}## Terms\r\n- **A** — a\r\n  - heard: ay\r- **B**\n")
        #expect(g.terms == [GlossaryEntry(term: "A", description: "a", heard: ["ay"]), GlossaryEntry(term: "B")])
    }

    @Test func unicodeTerms() {
        let g = GlossaryParser.parse("## People\n- **Siobhán Ó Súilleabháin** — heard: shiv on o sullivan\n- Zoë — 👋 friend\n- 北京 — Beijing\n")
        #expect(g.people.map(\.term) == ["Siobhán Ó Súilleabháin", "Zoë", "北京"])
        #expect(g.entry("Zoë")?.description == "👋 friend")
    }

    @Test(arguments: [
        "",
        "\n\n\n",
        "#",
        "##",
        "## ",
        "- ",
        "- **",
        "- ****",
        "- ** **",
        "- !",
        "- — description only",
        "- : x",
        "  - heard:",
        "<!--",
        "-->",
        "## Terms\n- **",
        "## Terms\n- heard:\n  - heard:",
        "## Terms\n- **A** — heard:",
        "## Terms\n\t\t\t",
        String(repeating: "- **x** — ", count: 200),
        "## Patterns\n- {n}\n- **{n}**",
        "```\n## Terms\n- **A**\n```",
    ])
    func neverFailsOnOddInput(text: String) {
        let g = GlossaryParser.parse(text)
        // Every line is kept somewhere, and the writer gives back something that parses the same.
        #expect(GlossaryParser.parse(GlossaryWriter.markdown(g)) == g)
        for e in g.allEntries.map(\.entry) { #expect(!e.term.isEmpty) }
    }

    @Test func headingKinds() {
        #expect(GlossarySectionKind.forHeading("Terms") == .terms)
        #expect(GlossarySectionKind.forHeading("  vocabulary: ") == .terms)
        #expect(GlossarySectionKind.forHeading("Names") == .people)
        #expect(GlossarySectionKind.forHeading("PATTERNS") == .patterns)
        #expect(GlossarySectionKind.forHeading("Style") == .style)
        #expect(GlossarySectionKind.forHeading("Acronyms we avoid") == .other)
        // A level-three heading is not a section.
        let g = GlossaryParser.parse("## Terms\n### People\n- **A**\n")
        #expect(g.sections.count == 1)
        #expect(g.terms.map(\.term) == ["A"])
    }

    @Test func entriesOnlyInKnownSections() {
        let g = GlossaryParser.parse("- **Before** — preamble\n## Style\n- **Bold** — style text\n## Whatever\n- **X**\n")
        #expect(g.allEntries.isEmpty)
        #expect(g.styleText == "- **Bold** — style text")
    }
}
