import Testing
@testable import DevshoutCore

@Suite struct GlossaryEditorTests {
    func add(_ heard: String?, _ term: String, _ kind: GlossaryEditor.CorrectionKind = .term, to text: String) -> String {
        GlossaryEditor.addingCorrection(heard: heard, term: term, kind: kind, to: text)
    }

    @Test func addsToAnExistingHeardSubBullet() {
        let text = "## Terms\n- **CORSIA** — scheme\n  - heard: core sea\n- **NDC**\n"
        #expect(add("corsair", "corsia", to: text) == "## Terms\n- **CORSIA** — scheme\n  - heard: core sea, corsair\n- **NDC**\n")
    }

    @Test func addsToAnInlineHeardList() {
        #expect(add("chevonne", "Siobhán Murphy", .person, to: "## People\n- **Siobhán Murphy** — heard: shiv on\n")
            == "## People\n- **Siobhán Murphy** — heard: shiv on, chevonne\n")
        #expect(add("b", "X", to: "## Terms\n- **X** — x (heard: a)\n") == "## Terms\n- **X** — x (heard: a, b)\n")
        #expect(add("b", "X", to: "## Terms\n- **X** — heard: a <!-- keep me -->\n")
            == "## Terms\n- **X** — heard: a, b <!-- keep me -->\n")
        #expect(add("b", "X", to: "## Terms\n- **X** — heard:\n") == "## Terms\n- **X** — heard: b\n")
    }

    @Test func keepsFullStopsAndBracketsAroundTheList() {
        #expect(add("n d c", "NDC", to: "## Terms\n- **NDC**\n  - heard: endy see, en dee see.\n")
            == "## Terms\n- **NDC**\n  - heard: endy see, en dee see, n d c.\n")
        #expect(add("corsair", "CORSIA", to: "## Terms\n- **CORSIA** — scheme (heard: core sea).\n")
            == "## Terms\n- **CORSIA** — scheme (heard: core sea, corsair).\n")
        #expect(add("corsair", "CORSIA", to: "## Terms\n- **CORSIA** (heard: core sea) — scheme\n")
            == "## Terms\n- **CORSIA** (heard: core sea, corsair) — scheme\n")
        #expect(add("b", "X", to: "## Terms\n- **X** — x [heard: a.]\n") == "## Terms\n- **X** — x [heard: a, b.]\n")
        // The edited mishearings still work.
        let edited = add("n d c", "NDC", to: add("corsair", "CORSIA", to:
            "## Terms\n- **NDC**\n  - heard: endy see, en dee see.\n- **CORSIA** — scheme (heard: core sea).\n"))
        let fixer = TextFixer(glossary: GlossaryParser.parse(edited))
        #expect(fixer.fix("en dee see, core sea, n d c and corsair").text == "NDC, CORSIA, NDC and CORSIA")
    }

    @Test func fallsBackToASubBulletWhenTheMarkerIsHardToFind() {
        #expect(add("b", "X", to: "## Terms\n- **X** <!-- c --> — heard: a\n")
            == "## Terms\n- **X** <!-- c --> — heard: a\n  - heard: b\n")
    }

    @Test func addsAHeardSubBulletAfterTheEntry() {
        let text = "## Terms\n- **CORSIA** — scheme\n  - see also: ICAO\n- **NDC**\n"
        #expect(add("core sea", "CORSIA", to: text)
            == "## Terms\n- **CORSIA** — scheme\n  - see also: ICAO\n  - heard: core sea\n- **NDC**\n")
    }

    @Test func leavesTheTextAloneWhenAlreadyListed() {
        let text = "## Terms\r\n- **CORSIA**\r\n  - heard: Core Sea\r\n"
        #expect(add("core sea", "CORSIA", to: text) == text)
        #expect(add(nil, "CORSIA", to: text) == text)
        #expect(add("corsia", "CORSIA", to: text) == text)
        #expect(add("x", "  ", to: text) == text)
    }

    @Test func addsANewEntryAtTheEndOfItsSection() {
        let text = "# G\n\n## Terms\n- **A**\n\n## People\n- **P**\n\n## Style\nBritish.\n"
        #expect(add("bee", "B", to: text) == "# G\n\n## Terms\n- **A**\n- **B**\n  - heard: bee\n\n## People\n- **P**\n\n## Style\nBritish.\n")
        #expect(add("shiv on", "Siobhán", .person, to: text)
            == "# G\n\n## Terms\n- **A**\n\n## People\n- **P**\n- **Siobhán**\n  - heard: shiv on\n\n## Style\nBritish.\n")
        #expect(add(nil, "B", to: "## Terms\n") == "## Terms\n- **B**\n")
    }

    @Test func addsAMissingSection() {
        #expect(add("bee", "B", to: "## Style\nBritish.") == "## Style\nBritish.\n\n## Terms\n- **B**\n  - heard: bee\n")
        #expect(add("bee", "B", .person, to: "") == "## People\n- **B**\n  - heard: bee\n")
    }

    @Test func worksOnTheStarterTemplate() {
        let out = add("core sea", "CORSIA", to: GlossaryFile.starterTemplate)
        let g = GlossaryParser.parse(out)
        #expect(g.terms == [GlossaryEntry(term: "CORSIA", heard: ["core sea"])])
        #expect(out.contains("-->\n- **CORSIA**\n  - heard: core sea\n\n## People"))
    }

    @Test func cleansInput() {
        #expect(add(" core,\nsea ", "CORSIA", to: "") == "## Terms\n- **CORSIA**\n  - heard: core sea\n")
    }

    @Test func saysWhenAMishearingWentOnAnExistingEntry() {
        let text = "## Terms\n- **CORSIA** — scheme\n  - heard: core sea\n"
        let result = GlossaryEditor.applyingCorrection(heard: "corsair", term: "corsia", to: text)
        #expect(result.outcome == .addedToExisting(term: "CORSIA"))
        #expect(result.markdown == "## Terms\n- **CORSIA** — scheme\n  - heard: core sea, corsair\n")
        #expect(result.changed)
    }

    @Test func saysWhenANewEntryWasAdded() {
        let text = "## Terms\n- **A**\n"
        let result = GlossaryEditor.applyingCorrection(heard: "shiv on", term: " Siobhán ", kind: .person, to: text)
        #expect(result.outcome == .addedNewEntry(term: "Siobhán", kind: .person))
        #expect(result.markdown == "## Terms\n- **A**\n\n## People\n- **Siobhán**\n  - heard: shiv on\n")
        #expect(result.changed)
        // The same edit as addingCorrection.
        #expect(result.markdown == add("shiv on", " Siobhán ", .person, to: text))
    }

    @Test func saysWhenNothingChanged() {
        let text = "## Terms\r\n- **CORSIA**\r\n  - heard: Core Sea\r\n"
        let listed = GlossaryEditor.applyingCorrection(heard: "core sea", term: "CORSIA", to: text)
        #expect(listed.outcome == .alreadyListed(term: "CORSIA"))
        #expect(listed.markdown == text)
        #expect(!listed.changed)
        #expect(GlossaryEditor.applyingCorrection(heard: nil, term: "corsia", to: text).outcome
            == .alreadyListed(term: "CORSIA"))
        let blank = GlossaryEditor.applyingCorrection(heard: "x", term: " , ", to: text)
        #expect(blank.outcome == .nothingToAdd)
        #expect(blank.markdown == text)
    }

    @Test func findsTheEntryACorrectionWouldGoOn() {
        let text = "## Terms\n- **CORSIA**\n<!--\n- **Hidden**\n-->\n## People\n- !**Siobhán Murphy** — heard: shiv on\n"
        #expect(GlossaryEditor.existingTerm(matching: " corsia ", in: text) == "CORSIA")
        #expect(GlossaryEditor.existingTerm(matching: "siobhán murphy", in: text) == "Siobhán Murphy")
        #expect(GlossaryEditor.existingTerm(matching: "hidden", in: text) == nil)   // commented out
        #expect(GlossaryEditor.existingTerm(matching: "NDC", in: text) == nil)
        #expect(GlossaryEditor.existingTerm(matching: "  ", in: text) == nil)
    }

    @Test func resultParses() throws {
        let messy = try GlossaryFixtures.text("messy.md")
        let out = add("bass lines", "Baseline", to: messy)
        let g = GlossaryParser.parse(out)
        #expect(g.terms.first { $0.term == "Baseline" }?.heard == ["base line", "bass lines"])
        // Only that one line changed.
        let before = GlossaryParser.lines(of: messy), after = GlossaryParser.lines(of: out)
        #expect(before.count == after.count)
        #expect(zip(before, after).filter { $0 != $1 }.count == 1)
    }
}
