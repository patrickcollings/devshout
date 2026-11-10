import Foundation
import Testing
@testable import DevshoutCore

@Suite struct ClaudeResultParserTests {
    func run(_ fixture: String, exitCode: Int32 = 0, stderr: String = "") throws -> ProcessResult {
        ProcessResult(exitCode: exitCode, stdout: try ClaudeTestSupport.fixtureData(fixture),
                      stderr: Data(stderr.utf8), timedOut: false, elapsed: 1)
    }

    @Test func decodesTheResultShape() throws {
        let output = try #require(ClaudeResultParser.decode(try ClaudeTestSupport.fixtureData("ok.json")))
        #expect(output.type == "result")
        #expect(output.subtype == "success")
        #expect(output.isError == false)
        #expect(output.result == "Check the CORSIA flag on AB-1234 in My Supply.")
        #expect(output.durationMs == 2310)
        #expect(output.numTurns == 1)
        #expect(output.totalCostUSD == 0.0012)
        #expect(output.usage?.inputTokens == 1450)
        #expect(output.usage?.outputTokens == 14)
        #expect(output.models == ["claude-haiku-4-5-20251001"])
    }

    @Test func success() throws {
        let result = ClaudeResultParser.interpret(try run("ok.json"))
        #expect(result == .success("Check the CORSIA flag on AB-1234 in My Supply."))
    }

    @Test func toleratesNoiseExtraFieldsAndBadTypes() throws {
        let data = try ClaudeTestSupport.fixtureData("ok-pretty-with-noise.txt")
        let output = try #require(ClaudeResultParser.decode(data))
        #expect(output.durationMs == 1800)
        #expect(output.usage == nil)
        #expect(ClaudeResultParser.interpret(try run("ok-pretty-with-noise.txt")) == .success("The tidied text."))
    }

    @Test func authFailureOnStdout() throws {
        guard case .failure(.authFailed(let message)) = ClaudeResultParser.interpret(try run("auth-401.json", exitCode: 1))
        else { Issue.record("expected authFailed"); return }
        #expect(message.contains("401"))
    }

    /// Captured from Claude Code 2.1.322 run by `ClaudeInvocation` with a made-up token.
    @Test func realAuthFailure() throws {
        let run = try run("real-2.1.322-auth-401.json", exitCode: 1)
        let output = try #require(ClaudeResultParser.decode(run.stdout))
        #expect(output.apiErrorStatus == 401)
        #expect(output.terminalReason == "api_error")
        #expect(ClaudeResultParser.interpret(run)
                == .failure(.authFailed(message: "Failed to authenticate. API Error: 401 OAuth access token is invalid.")))
    }

    @Test func status401IsAuthWhateverTheMessage() {
        let stdout = #"{"type":"result","is_error":true,"api_error_status":401,"result":"Something odd"}"#
        #expect(ClaudeResultParser.interpret(StubRunner.result(stdout: stdout, exitCode: 1))
                == .failure(.authFailed(message: "Something odd")))
    }

    @Test func authFailureEvenWithExitZero() throws {
        guard case .failure(.authFailed) = ClaudeResultParser.interpret(try run("not-logged-in.json")) else {
            Issue.record("expected authFailed"); return
        }
    }

    @Test func invalidAPIKeyMessageIsAnAuthFailure() throws {
        guard case .failure(.authFailed) = ClaudeResultParser.interpret(try run("invalid-api-key.json", exitCode: 1))
        else { Issue.record("expected authFailed"); return }
    }

    @Test func rateLimitIsAProcessFailure() throws {
        let result = ClaudeResultParser.interpret(try run("rate-limit.json", exitCode: 1))
        #expect(result == .failure(.processFailed(exitCode: 1, message: "Claude AI usage limit reached|1794321000")))
    }

    @Test func outputTokenLimitIsNotAnAuthFailure() throws {
        guard case .failure(.processFailed) = ClaudeResultParser.interpret(try run("output-token-limit.json", exitCode: 1))
        else { Issue.record("expected processFailed"); return }
    }

    @Test func errorSubtypeWithoutResult() throws {
        let result = ClaudeResultParser.interpret(try run("error-max-turns.json", exitCode: 0))
        #expect(result == .failure(.processFailed(exitCode: 0, message: "Claude stopped early (error_max_turns)")))
    }

    @Test func emptyResultIsRejected() throws {
        guard case .failure(.rejectedOutput) = ClaudeResultParser.interpret(try run("empty-result.json")) else {
            Issue.record("expected rejectedOutput"); return
        }
    }

    @Test func nonJSONWithExitZeroIsRejected() {
        let run = StubRunner.result(stdout: "Hello! How can I help?")
        guard case .failure(.rejectedOutput(let reason)) = ClaudeResultParser.interpret(run) else {
            Issue.record("expected rejectedOutput"); return
        }
        #expect(reason.contains("Hello! How can I help?"))
    }

    @Test func nothingAtAllIsRejected() {
        guard case .failure(.rejectedOutput) = ClaudeResultParser.interpret(StubRunner.result()) else {
            Issue.record("expected rejectedOutput"); return
        }
    }

    @Test func nonJSONFailureUsesStderr() {
        let run = StubRunner.result(stdout: "", stderr: "error: unknown option '--frobnicate'", exitCode: 1)
        #expect(ClaudeResultParser.interpret(run)
                == .failure(.processFailed(exitCode: 1, message: "error: unknown option '--frobnicate'")))
    }

    @Test func nonJSONAuthFailureOnStderr() {
        let run = StubRunner.result(stderr: "OAuth token revoked", exitCode: 1)
        #expect(ClaudeResultParser.interpret(run) == .failure(.authFailed(message: "OAuth token revoked")))
    }

    @Test func ndjsonTakesTheLastResultLine() {
        let stdout = """
            {"type":"system","subtype":"init"}
            {"type":"result","subtype":"success","is_error":false,"result":"final"}
            """
        #expect(ClaudeResultParser.interpret(StubRunner.result(stdout: stdout)) == .success("final"))
    }

    @Test(arguments: [
        ("Failed to authenticate. API Error: 401", true),
        ("OAuth token has expired", true),
        ("Invalid API key · Please run /login", true),
        ("Not logged in", true),
        ("Your token is invalid", true),
        ("authentication_error", true),
        ("Unauthorized", true),
        ("Claude AI usage limit reached", false),
        ("API Error: 529 Overloaded", false),
        ("response exceeded the 32000 output token maximum", false),
        ("Request timed out", false),
        ("Something went wrong", false),
    ])
    func authHeuristic(message: String, isAuth: Bool) {
        #expect(ClaudeResultParser.looksLikeAuthFailure(message) == isAuth)
    }

    @Test func cleanTextStripsFencesAndTags() {
        #expect(ClaudeResultParser.cleanText("```\nhello\n```") == "hello")
        #expect(ClaudeResultParser.cleanText("```markdown\n# Goal\n\n1. Do it\n```\n") == "# Goal\n\n1. Do it")
        #expect(ClaudeResultParser.cleanText("<transcript>\nhello there\n</transcript>") == "hello there")
        #expect(ClaudeResultParser.cleanText("<transcript>```text\nhi\n```</transcript>") == "hi")
        #expect(ClaudeResultParser.cleanText("Some text with <Transcript> inside") == "Some text with  inside")
    }

    @Test func cleanTextKeepsInnerCodeBlocks() {
        let structured = "# Goal\n\nRun this:\n\n```bash\nswift test\n```\n\nThen push."
        #expect(ClaudeResultParser.cleanText(structured) == structured)
        let twoBlocks = "```swift\na()\n```\n\nand\n\n```swift\nb()\n```"
        #expect(ClaudeResultParser.cleanText(twoBlocks) == twoBlocks)
    }
}
