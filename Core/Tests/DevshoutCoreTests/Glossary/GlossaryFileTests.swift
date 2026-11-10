import Foundation
import Testing
@testable import DevshoutCore

@Suite struct GlossaryFileTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("glossary-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested/glossary.md")
    }

    @Test func missingFileGivesTheStarterTemplate() throws {
        let file = GlossaryFile(url: tempURL())
        #expect(!file.exists)
        #expect(try file.loadText() == GlossaryFile.starterTemplate)
        #expect(!file.exists, "loading must not create the file")
        let g = try file.load()
        #expect(g.allEntries.isEmpty)
        #expect(g.isEffectivelyEmpty)
        #expect(g.sections.compactMap(\.heading) == ["Terms", "People", "Patterns", "Style"])
    }

    @Test func starterTemplateExamplesWorkOnceUncommented() {
        // Removing the comment markers turns the examples into a working glossary.
        let lines = GlossaryFile.starterTemplate.components(separatedBy: "\n")
        var uncommented: [String] = []
        var inExplanation = false
        for line in lines {
            if line.hasPrefix("<!--") && line.count == 4 && uncommented.count <= 2 { inExplanation = true; continue }
            if inExplanation { if line == "-->" { inExplanation = false }; continue }
            if line == "<!--" || line == "-->" { continue }
            uncommented.append(line)
        }
        let g = GlossaryParser.parse(uncommented.joined(separator: "\n"))
        #expect(g.terms.map(\.term) == ["CORSIA", "NDC", "My Supply", "procurement", "proponent"])
        #expect(g.entry("CORSIA")?.heard.contains("core sea") == true)
        #expect(g.people.map(\.term) == ["Siobhán Murphy"])
        #expect(g.patterns.map(\.term) == ["AB-{n}"])
        #expect(!g.styleText.isEmpty)
        #expect(TextFixer(glossary: g).fix("core sea and a b one two three four").text == "CORSIA and AB-1234")
    }

    @Test func templateIsBritish() {
        let t = GlossaryFile.starterTemplate.lowercased()
        for american in ["color", "recognize", "organize", "capitalized", "behavior"] {
            #expect(!t.contains(american))
        }
    }

    @Test func savesAndLoads() throws {
        let file = GlossaryFile(url: tempURL())
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent().deletingLastPathComponent()) }
        let text = "## People\n- **Siobhán Murphy** — heard: shiv on\n"
        try file.save(text: text)
        #expect(file.exists)
        #expect(try file.loadText() == text)
        #expect(try file.load().people == [GlossaryEntry(term: "Siobhán Murphy", heard: ["shiv on"])])
        #expect(try Data(contentsOf: file.url) == Data(text.utf8))

        // Saving again replaces the file.
        try file.save(text: "## Terms\n- **NDC**\n")
        #expect(try file.load().terms.map(\.term) == ["NDC"])

        let g = try GlossaryFixtures.glossary("messy.md")
        try file.save(g)
        #expect(try file.load() == g)
    }

    @Test func toleratesBOMAndBadUTF8() throws {
        let file = GlossaryFile(url: tempURL())
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("## Terms\n- **A** — ".utf8))
        data.append(Data([0xFF, 0xFE]))
        data.append(Data("\n- **B**\n".utf8))
        try data.write(to: file.url)
        let text = try file.loadText()
        #expect(text.hasPrefix("## Terms"))
        #expect(try file.load().terms.map(\.term) == ["A", "B"])
    }

    @Test func defaultLocation() {
        let url = GlossaryFile.defaultURL(applicationSupport: URL(fileURLWithPath: "/Users/p/Library/Application Support"))
        #expect(url.path == "/Users/p/Library/Application Support/devshout/glossary.md")
    }
}
