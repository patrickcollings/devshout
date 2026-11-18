import Foundation
import Testing
@testable import DevshoutCore

/// The repository's real `bench/glossary.sample.md` (Core/Tests/DevshoutCoreTests/Calibration/…).
private let sampleGlossary: Glossary = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    let text = try! String(contentsOf: url.appendingPathComponent("bench/glossary.sample.md"), encoding: .utf8)
    return GlossaryParser.parse(text)
}()

private let smallGlossary = GlossaryParser.parse("""
    ## Terms
    - **CORSIA** — an aviation offsetting scheme
      - heard: core sea
    - **My Supply** — a product area
    - **proponent**
    """)

@Suite struct CalibrationTextTests {
    @Test func numberWordsBecomeDigits() {
        #expect(CalibrationText.words("forty-five minutes") == ["45", "minutes"])
        #expect(CalibrationText.words("45 minutes") == ["45", "minutes"])
        #expect(CalibrationText.words("three hundred and twenty users") == ["320", "users"])
        #expect(CalibrationText.words("two thousand and five") == ["2005"])
        #expect(CalibrationText.words("nineteen") == ["19"])
    }

    @Test func ordinalsAndPercent() {
        #expect(CalibrationText.words("Thursday the fourteenth of March") == ["thursday", "the", "14th", "of", "march"])
        #expect(CalibrationText.words("the thirty-first") == ["the", "31st"])
        #expect(CalibrationText.words("the third run") == ["the", "3rd", "run"])
        #expect(CalibrationText.words("20%") == ["20", "percent"])
        #expect(CalibrationText.words("twenty per cent") == ["20", "percent"])
        #expect(CalibrationText.words("20 percent") == ["20", "percent"])
    }

    @Test func separateDigitsStaySeparate() {
        #expect(CalibrationText.words("one two three") == ["1", "2", "3"])
        #expect(CalibrationText.words("1 in 5") == CalibrationText.words("one in five"))
    }

    @Test func wordsThatOnlyLookLikeNumbersAreLeftAlone() {
        #expect(CalibrationText.words("a hundred and one things") == ["a", "hundred", "and", "1", "things"])
        #expect(CalibrationText.words("bread and butter") == ["bread", "and", "butter"])
        #expect(CalibrationText.words("Article six") == CalibrationText.words("Article 6"))
    }

    @Test func theBuiltInSentencesScoreThemselvesPerfectly() {
        for sentence in CalibrationScriptBuilder.generalSentences {
            #expect(CalibrationScorer.alignment(reference: sentence, transcript: sentence).errors == 0)
        }
    }
}

@Suite struct CalibrationScriptTests {
    @Test func anEmptyGlossaryGivesTenGeneralSentences() {
        let script = CalibrationScriptBuilder.script(glossary: .empty)
        #expect(script.count == 10)
        #expect(script.allSatisfy { $0.kind == .general && $0.terms.isEmpty && $0.source == .builtIn })
        #expect(script.map(\.id) == ["c01", "c02", "c03", "c04", "c05", "c06", "c07", "c08", "c09", "c10"])
        #expect(Set(script.map(\.text)).count == 10)
        // The starter template is all comments: it counts as empty.
        #expect(CalibrationScriptBuilder.script(glossary: GlossaryParser.parse(GlossaryFile.starterTemplate)).allSatisfy { $0.kind == .general })
    }

    @Test func halfTheScriptUsesGlossaryTerms() {
        let script = CalibrationScriptBuilder.script(glossary: sampleGlossary)
        #expect(script.count == 10)
        #expect(script.prefix(5).allSatisfy { $0.kind == .general })
        let glossarySentences = script.suffix(5)
        #expect(glossarySentences.allSatisfy { $0.kind == .glossary && !$0.terms.isEmpty && $0.source == .builtIn })
        for sentence in glossarySentences {
            for term in sentence.terms {
                #expect(TermHitRate.evaluate(terms: [term], reference: sentence.text, hypothesis: sentence.text).hits == 1,
                        "\(sentence.text) should contain \(term)")
            }
        }
        #expect(Set(script.map(\.text)).count == 10)
    }

    @Test func termGroupsPutPinnedTermsFirstAndGiveSlotsToPeopleAndATicket() {
        let groups = CalibrationScriptBuilder.termGroups(for: sampleGlossary)
        #expect(groups.count == 5)
        // Three term sentences of two terms each, pinned entries first; then a person and a ticket.
        #expect(groups[0].terms == ["CORSIA", "My Supply"])
        #expect(groups[1].terms == ["NDC", "proponent"])
        #expect(groups[2].terms == ["procurement", "PDD"])
        #expect(groups[3] == CalibrationTermGroup(kind: .people, terms: ["Declan Hollings"], descriptions: [nil]))
        #expect(groups[4].kind == .ticket)
        #expect(groups[4].terms == ["AB-1482"])
    }

    @Test func aSmallGlossaryGetsFewerGlossarySentencesAndMoreGeneralOnes() {
        let groups = CalibrationScriptBuilder.termGroups(for: smallGlossary)
        #expect(groups.map(\.terms) == [["CORSIA"], ["My Supply"], ["proponent"]])
        let script = CalibrationScriptBuilder.script(glossary: smallGlossary)
        #expect(script.count == 10)
        #expect(script.filter { $0.kind == .general }.count == 7)
        #expect(script.suffix(3).map(\.terms) == [["CORSIA"], ["My Supply"], ["proponent"]])
    }

    @Test func claudeSentencesAreUsedWhenTheyPassTheChecks() {
        let output = """
            1. Could you confirm that the CORSIA rules still apply to this airline before we publish?
            2. I opened My Supply this morning and two of the rows looked wrong to me.
            3. The proponent has not replied yet, so let's wait until tomorrow afternoon.
            """
        let script = CalibrationScriptBuilder.script(glossary: smallGlossary, claudeOutput: output)
        let glossarySentences = Array(script.suffix(3))
        #expect(glossarySentences.allSatisfy { $0.source == .claude })
        #expect(glossarySentences[0].text == "Could you confirm that the CORSIA rules still apply to this airline before we publish?")
        #expect(glossarySentences[1].terms == ["My Supply"])
    }

    @Test func aClaudeSentenceWithoutItsTermFallsBackToTheTemplate() {
        let output = """
            1. Could you confirm that the Corsia rules still apply to this airline before we publish?
            2. I opened my supply this morning and two of the rows looked wrong to me.
            3. The proponent has not replied yet, so let's wait until tomorrow afternoon.
            """
        let script = Array(CalibrationScriptBuilder.script(glossary: smallGlossary, claudeOutput: output).suffix(3))
        // Wrong capitals are not the term.
        #expect(script.map(\.source) == [.builtIn, .builtIn, .claude])
        #expect(script[0].text.contains("CORSIA"))
        #expect(script[1].text.contains("My Supply"))
    }

    @Test func rubbishFromClaudeGivesTheBuiltInSentences() {
        let builtIn = CalibrationScriptBuilder.script(glossary: smallGlossary)
        for output in ["", "I'm sorry, I can't help with that.", "```json\n{\"sentences\": []}\n```",
                       "1. CORSIA\n2. My Supply\n3. proponent",
                       "1. **CORSIA** is a scheme that applies to international flights between countries.",
                       "1. " + Array(repeating: "CORSIA is very long", count: 12).joined(separator: " ") + "."] {
            #expect(CalibrationScriptBuilder.script(glossary: smallGlossary, claudeOutput: output) == builtIn, "\(output)")
        }
    }

    @Test func unnumberedOrMisnumberedLinesAreMatchedByTheirTerms() {
        let groups = CalibrationScriptBuilder.termGroups(for: smallGlossary)
        let unnumbered = """
            Here are the sentences:
            - "The proponent has not replied yet, so let's wait until tomorrow afternoon."
            - Could you confirm that the CORSIA rules still apply to this airline?
            """
        let found = CalibrationScriptBuilder.sentences(fromClaude: unnumbered, for: groups)
        #expect(found == ["Could you confirm that the CORSIA rules still apply to this airline?", nil,
                          "The proponent has not replied yet, so let's wait until tomorrow afternoon."])

        let misnumbered = "3) Could you confirm that the CORSIA rules still apply to this airline?"
        #expect(CalibrationScriptBuilder.sentences(fromClaude: misnumbered, for: groups).first
                == "Could you confirm that the CORSIA rules still apply to this airline?")
    }

    @Test func aScriptRoundTripsThroughItsTextFile() {
        let script = CalibrationScriptBuilder.script(glossary: smallGlossary)
        let text = CalibrationScriptFile.render(script)
        #expect(text.hasPrefix("- c01: Could you check whether the login page"))
        #expect(CalibrationScriptFile.parse(text, glossaryTerms: CalibrationScorer.glossaryTerms(smallGlossary)) == script)
        let loose = "# Notes\nfirst: Hello there, how are you?\n- first: A repeat.\n- bad id!: No.\n- s02:\n"
        #expect(CalibrationScriptFile.parse(loose) == [CalibrationSentence(id: "first", text: "Hello there, how are you?", kind: .general)])
    }

    @Test func theRequestListsEveryGroupWithItsDescriptions() {
        let groups = CalibrationScriptBuilder.termGroups(for: smallGlossary)
        let request = CalibrationScriptBuilder.claudeRequest(for: groups)
        #expect(request.message == "1. CORSIA (an aviation offsetting scheme)\n2. My Supply (a product area)\n3. proponent\n")
        #expect(request.systemPrompt.contains("British English"))
        #expect(request.systemPrompt.contains("exactly as written"))
    }

    @Test func theWriterIsAskedOnceAndItsFailureIsNotFatal() async {
        let calls = CallCounter()
        let good = await CalibrationScriptBuilder.script(glossary: smallGlossary, writer: { request in
            calls.increment()
            #expect(request.message.hasPrefix("1. CORSIA"))
            return "1. Could you confirm that the CORSIA rules still apply to this airline?"
        })
        #expect(calls.value == 1)
        #expect(good.filter { $0.source == .claude }.count == 1)

        let failed = await CalibrationScriptBuilder.script(glossary: smallGlossary, writer: { _ in throw CleanError.notConnected })
        #expect(failed == CalibrationScriptBuilder.script(glossary: smallGlossary))

        // With nothing to write about, Claude isn't asked at all.
        let empty = await CalibrationScriptBuilder.script(glossary: .empty, writer: { _ in
            calls.increment()
            return ""
        })
        #expect(calls.value == 1)
        #expect(empty.count == 10)
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite struct ClaudeSentenceWriterTests {
    func writer(runner: StubRunner, credential: ClaudeCredential? = ClaudeTestSupport.credential,
                installed: Bool = true) throws -> (ClaudeSentenceWriter, URL) {
        let root = try ClaudeTestSupport.temporaryDirectory("sentences")
        let installation = ClaudeInstallation(url: URL(fileURLWithPath: "/opt/bin/claude"), version: ClaudeVersion(2, 1, 300))
        let writer = ClaudeSentenceWriter(installation: { installed ? installation : nil },
                                          credential: { credential },
                                          configDirectory: root.appendingPathComponent("config"),
                                          workingDirectory: root.appendingPathComponent("cwd"),
                                          runner: runner, host: ClaudeTestSupport.host)
        return (writer, root)
    }

    let request = CalibrationSentenceRequest(systemPrompt: "Write sentences.", message: "1. CORSIA\n")

    @Test func runsClaudeLikeACleanUpWithItsOwnInstructions() async throws {
        let stdout = #"{"type":"result","subtype":"success","is_error":false,"result":"1. Check the CORSIA flag before the release."}"#
        let runner = StubRunner { _ in StubRunner.result(stdout: stdout) }
        let (writer, root) = try writer(runner: runner)
        let text = try await writer.write(request)
        #expect(text == "1. Check the CORSIA flag before the release.")

        let sent = try #require(runner.requests.first)
        #expect(runner.requests.count == 1)
        #expect(sent.arguments.prefix(2) == ["-p", CalibrationScriptBuilder.claudePrompt])
        #expect(sent.arguments.contains("--system-prompt"))
        #expect(sent.arguments.contains("Write sentences."))
        // Tools off, one turn, haiku: the same guard rails as a clean-up.
        let tools = try #require(sent.arguments.firstIndex(of: "--tools"))
        #expect(sent.arguments[tools + 1] == "")
        #expect(sent.arguments.contains("--strict-mcp-config"))
        #expect(!sent.arguments.contains("--bare"))
        let model = try #require(sent.arguments.firstIndex(of: "--model"))
        #expect(sent.arguments[model + 1] == "haiku")
        #expect(sent.stdin == Data("1. CORSIA\n".utf8))
        #expect(sent.timeout == 30)
        #expect(sent.environment["CLAUDE_CODE_OAUTH_TOKEN"] == ClaudeTestSupport.credential.token)
        #expect(sent.environment["CLAUDE_CONFIG_DIR"] == root.appendingPathComponent("config").path)
        #expect(sent.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(sent.currentDirectory?.path == root.appendingPathComponent("cwd").path)
    }

    @Test func failuresAreCleanErrors() async throws {
        let unused = StubRunner { _ in StubRunner.result() }
        let (notConnected, _) = try writer(runner: unused, credential: nil)
        await #expect(throws: CleanError.notConnected) { try await notConnected.write(request) }
        let (notInstalled, _) = try writer(runner: unused, installed: false)
        await #expect(throws: CleanError.claudeNotFound) { try await notInstalled.write(request) }
        #expect(unused.requests.isEmpty)

        let slow = StubRunner { _ in StubRunner.result(timedOut: true) }
        let (timedOut, _) = try writer(runner: slow)
        await #expect(throws: CleanError.timedOut(after: 30)) { try await timedOut.write(request) }
    }

    @Test func aCleanUpStillUsesItsOwnPrompt() {
        let invocation = ClaudeInvocation(executable: URL(fileURLWithPath: "/opt/bin/claude"), model: "haiku",
                                          systemPrompt: .inline("x"), stdin: "y", credential: ClaudeTestSupport.credential,
                                          configDirectory: nil, workingDirectory: URL(fileURLWithPath: "/tmp"),
                                          host: ClaudeTestSupport.host)
        #expect(invocation.arguments.prefix(2) == ["-p", PromptBuilder.userPrompt])
    }
}
