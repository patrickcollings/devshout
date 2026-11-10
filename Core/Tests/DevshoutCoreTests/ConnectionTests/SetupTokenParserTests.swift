import Foundation
import Testing
@testable import DevshoutCore

@Suite struct TerminalRendererTests {
    @Test func cursorToColumnSeparatesWords() {
        let r = TerminalRenderer.render("\u{1B}[2GPaste\u{1B}[8Gcode\u{1B}[13Ghere\r\r\n")
        #expect(r.screenLines.first == " Paste code here")
        #expect(r.plainLines.first == "Paste code here")
    }

    @Test func carriageReturnOverwritesOnScreenButKeepsBothInPlainText() {
        let r = TerminalRenderer.render("⠋ Waiting\r⠙ Waiting\r⠹ Done   ")
        #expect(r.screenLines == ["⠹ Done"])
        #expect(r.plainLines == ["⠋ Waiting", "⠙ Waiting", "⠹ Done   "])
    }

    @Test func eraseAndRedrawLikeInk() {
        let frame1 = "one\r\ntwo\r\nthree\r\n"
        let redraw = "\u{1B}[2K\u{1B}[1A\u{1B}[2K\u{1B}[1A\u{1B}[2K\u{1B}[1A\u{1B}[2K\u{1B}[Gfour\r\n"
        let r = TerminalRenderer.render(frame1 + redraw)
        #expect(r.screenLines.filter { !$0.isEmpty } == ["four"])
        #expect(r.plainLines.contains("two"))
    }

    @Test func clearScreenAndHome() {
        let r = TerminalRenderer.render("old stuff\r\nmore\r\n\u{1B}[2J\u{1B}[3J\u{1B}[Hnew")
        #expect(r.screenLines == ["new"])
    }

    @Test func cursorPositionAndEraseToEnd() {
        let r = TerminalRenderer.render("abcdef\r\n\u{1B}[1;3HXY\u{1B}[K")
        #expect(r.screenLines[0] == "abXY")
    }

    @Test func saveAndRestoreCursor() {
        let r = TerminalRenderer.render("\u{1B}7hello\r\nworld\u{1B}8J")
        #expect(r.screenLines[0] == "Jello")
    }

    @Test func osc8LinksAreCollectedAndTheirTextKept() {
        let r = TerminalRenderer.render("\u{1B}]8;id=1;https://example.com/a\u{07}click\u{1B}]8;;\u{07} and \u{1B}]8;;https://example.com/b\u{1B}\\b\u{1B}]8;;\u{1B}\\")
        #expect(r.hyperlinks == ["https://example.com/a", "https://example.com/b"])
        #expect(r.screenLines == ["click and b"])
    }

    @Test func incompleteEscapeAtTheEndIsIgnored() {
        #expect(TerminalRenderer.render("text\u{1B}[3").screenLines == ["text"])
        #expect(TerminalRenderer.render("text\u{1B}").screenLines == ["text"])
        #expect(TerminalRenderer.render("text\u{1B}]8;;https://x").hyperlinks.isEmpty)
    }

    @Test func privateModesAndQueriesHaveNoEffect() {
        let r = TerminalRenderer.render("\u{1B}[?25l\u{1B}[?2004hhi\u{1B}[>0q\u{1B}[?u\u{1B}]7501;?\u{07}\u{1B}[c\u{1B}(B\u{0F}!")
        #expect(r.screenLines == ["hi!"])
    }

    @Test func realCaptureRendersTheSignInScreen() {
        let screen = TerminalRenderer.render(CapturedSetupToken.wide).screenText
        #expect(screen.contains("Browser didn't open? Use the url below to sign in (c to copy)"))
        #expect(screen.contains(" Paste code here if prompted >"))
    }
}

@Suite struct SetupTokenParserTests {
    static let wideURL = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=XAeowmaxUV28adxjgiIHI_EEMAjLRyytxGRK685ZB14&code_challenge_method=S256&state=0DeSpL1zaSHxCdpVwSHACyB4G7LjCZd-p_nP8bOWcYA"
    static let narrowURL = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=qoaqc-JUVR8trZWMw_w3W_bJ9UrxiIYypd6ceEnUOZA&code_challenge_method=S256&state=1kdiETndz3iZ_FOatum2hfE0tsNOeNpFiC5zrYp7cjg"

    // MARK: Real captures

    @Test func wideSignInScreen() {
        let out = SetupTokenParser.parse(CapturedSetupToken.wide)
        #expect(out.token == nil)
        #expect(out.signInURL?.absoluteString == Self.wideURL)
        #expect(out.isPromptingForCode)
        #expect(out.errorMessage == nil)
        #expect(!out.isOfferingRetry)
    }

    @Test func narrowSignInScreenUsesTheFullHyperlink() {
        let out = SetupTokenParser.parse(CapturedSetupToken.narrow)
        #expect(out.signInURL?.absoluteString == Self.narrowURL)
        #expect(out.isPromptingForCode)
    }

    @Test func narrowSignInScreenWithoutHyperlinksJoinsTheWrappedURL() {
        let raw = SetupTokenSamples.withoutHyperlinks(CapturedSetupToken.narrow)
        #expect(!raw.contains("\u{1B}]8;"))
        let out = SetupTokenParser.parse(raw)
        #expect(out.signInURL?.absoluteString == Self.narrowURL)
    }

    @Test func wideSignInScreenWithoutHyperlinks() {
        let out = SetupTokenParser.parse(SetupTokenSamples.withoutHyperlinks(CapturedSetupToken.wide))
        #expect(out.signInURL?.absoluteString == Self.wideURL)
    }

    @Test func rejectedCodeShowsTheOAuthError() {
        let out = SetupTokenParser.parse(CapturedSetupToken.rejectedCode)
        #expect(out.token == nil)
        #expect(out.errorMessage?.hasPrefix("OAuth error: That code wasn't accepted.") == true)
        #expect(out.isOfferingRetry)
        #expect(!out.isPromptingForCode)  // the prompt was erased when the error was drawn
    }

    @Test func screenTextIsWhatIsShownNow() {
        let out = SetupTokenParser.parse(CapturedSetupToken.rejectedCode)
        #expect(out.screenText.contains("OAuth error"))
        #expect(!out.screenText.contains("Paste code here"))
        #expect(out.hasVisibleText)
    }

    // MARK: Success

    @Test func tokenFromAWideSuccessfulRun() {
        let out = SetupTokenParser.parse(SetupTokenSamples.fullSuccessfulRun())
        #expect(out.token == SetupTokenSamples.token)
        #expect(!out.isPromptingForCode)
        #expect(out.errorMessage == nil)
        #expect(out.statedValidity == TimeInterval(365 * 86_400))
        #expect(!out.screenText.contains(SetupTokenSamples.token))
        #expect(out.screenText.contains("created successfully"))
    }

    @Test func tokenHardWrappedAtEightyColumns() {
        let raw = SetupTokenSamples.fullSuccessfulRun(width: 80)
        #expect(!raw.contains(SetupTokenSamples.token))  // really split
        let out = SetupTokenParser.parse(raw)
        #expect(out.token == SetupTokenSamples.token)
    }

    @Test func tokenHardWrappedAtFortyColumnsOverThreeLines() {
        let out = SetupTokenParser.parse(SetupTokenSamples.successFrame(width: 40) + "\r\r\n")
        #expect(out.token == SetupTokenSamples.token)
    }

    @Test func tokenInsideABox() {
        let t = SetupTokenSamples.token
        let raw = "╭──────╮\r\n│ Your OAuth token: │\r\n│ \(t.prefix(60)) │\r\n│ \(t.dropFirst(60)) │\r\n╰──────╯\r\n"
        #expect(SetupTokenParser.parse(raw).token == t)
    }

    @Test func tokenWithCarriageReturnsAndNoColour() {
        let raw = "Your OAuth token (valid for 1 year):\r\n\r\n\(SetupTokenSamples.token)\r\n\r\nStore this token securely.\r\n"
        #expect(SetupTokenParser.parse(raw).token == SetupTokenSamples.token)
    }

    @Test func tokenFollowedBySpaceOnTheSameLine() {
        let raw = "token: \(SetupTokenSamples.token)  (copied)"
        #expect(SetupTokenParser.parse(raw).token == SetupTokenSamples.token)
    }

    @Test func tokenWithLineFeedsOnly() {
        let raw = "Your OAuth token:\n\(SetupTokenSamples.token)\n\nStore this token securely.\n"
        #expect(SetupTokenParser.parse(raw).token == SetupTokenSamples.token)
    }

    @Test func otherTokenShapesAreAccepted() {
        let t = "sk-ant-oat02-" + String(repeating: "aB3_-", count: 18)
        #expect(SetupTokenParser.parse("\(t)\r\n\r\n").token == t)
    }

    @Test func apiKeysAreNeverPickedUp() {
        let key = "sk-ant-api03-" + String(repeating: "x", count: 90) + "AA"
        #expect(SetupTokenParser.parse("\(key)\r\n\r\n", finished: true).token == nil)
    }

    @Test func mentionsOfThePrefixAreNotTokens() {
        let raw = "Tokens start sk-ant-oat01- and are secret.\r\nUse sk-ant-…\r\n"
        #expect(SetupTokenParser.parse(raw, finished: true).token == nil)
    }

    @Test func placeholderLineIsNotAToken() {
        let out = SetupTokenParser.parse(SetupTokenSamples.inkLine("Use this token by setting: export CLAUDE_CODE_OAUTH_TOKEN=<token>"), finished: true)
        #expect(out.token == nil)
    }

    @Test func theLatestTokenWins() {
        let older = "sk-ant-oat01-" + String(repeating: "o", count: 80)
        let raw = "\(older)\r\n\r\n" + SetupTokenSamples.successFrame() + "\r\r\n"
        #expect(SetupTokenParser.parse(raw).token == SetupTokenSamples.token)
    }

    // MARK: Streaming

    /// Feeding the run one scalar at a time must never yield a truncated token or URL.
    @Test func everyPrefixGivesNothingOrTheWholeToken() {
        for width in [4_000, 80] {
            let raw = SetupTokenSamples.fullSuccessfulRun(width: width)
            let scalars = Array(raw.unicodeScalars)
            var firstFound: Int?
            for end in stride(from: 0, through: scalars.count, by: 7) {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[0..<end])
                let out = SetupTokenParser.parse(String(view))
                if let token = out.token {
                    #expect(token == SetupTokenSamples.token, "width \(width), prefix \(end)")
                    if firstFound == nil { firstFound = end }
                }
                if let url = out.signInURL {
                    #expect(url.absoluteString == (width == 80 ? Self.narrowURL : Self.wideURL), "width \(width), prefix \(end)")
                }
            }
            #expect(firstFound != nil)
        }
    }

    @Test func everyPrefixOfPlainURLGivesNothingOrTheWholeURL() {
        let raw = SetupTokenSamples.withoutHyperlinks(CapturedSetupToken.narrow)
        let scalars = Array(raw.unicodeScalars)
        // Every prefix is quadratic and took over 30 s on CI, starving the timing-sensitive tests running in
        // parallel. A coarse stride plus every prefix around the URL keeps the coverage that matters.
        let urlStart = raw.unicodeScalars.distance(from: raw.unicodeScalars.startIndex,
                                                   to: raw.range(of: "https://")?.lowerBound.samePosition(in: raw.unicodeScalars) ?? raw.unicodeScalars.startIndex)
        let near = Set(max(0, urlStart - 20)...min(scalars.count, urlStart + 400))
        let ends = Set(stride(from: 0, through: scalars.count, by: 11)).union(near).union([scalars.count]).sorted()
        for end in ends {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[0..<end])
            if let url = SetupTokenParser.parse(String(view)).signInURL {
                #expect(url.absoluteString == Self.narrowURL, "prefix \(end)")
            }
        }
    }

    @Test func tokenAtTheVeryEndCountsOnlyOnceFinished() {
        let raw = "Your OAuth token:\r\n\(SetupTokenSamples.token)"
        #expect(SetupTokenParser.parse(raw).token == nil)
        #expect(SetupTokenParser.parse(raw, finished: true).token == SetupTokenSamples.token)
        #expect(SetupTokenParser.parse(raw + "\r").token == nil)  // the next line might continue it
        #expect(SetupTokenParser.parse(raw + "\r\r\n\r\r\n").token == SetupTokenSamples.token)
    }

    @Test func dataAcrossAUTF8Boundary() {
        var data = Data(SetupTokenSamples.fullSuccessfulRun().utf8)
        #expect(SetupTokenParser.parse(data).token == SetupTokenSamples.token)
        data.append(0xE2)  // the first byte of "✓": decodes as a replacement character, harmlessly
        #expect(SetupTokenParser.parse(data).token == SetupTokenSamples.token)
    }

    // MARK: URLs

    @Test func urlWithTrailingPunctuation() {
        let raw = "Open https://claude.ai/oauth/authorize?client_id=abc&state=xyz.\r\nThen come back.\r\n"
        #expect(SetupTokenParser.parse(raw).signInURL?.absoluteString == "https://claude.ai/oauth/authorize?client_id=abc&state=xyz")
    }

    @Test func docsLinksAreNotSignInLinks() {
        let raw = "See https://code.claude.com/docs/en/authentication for help.\r\n\r\n"
        #expect(SetupTokenParser.parse(raw, finished: true).signInURL == nil)
    }

    @Test func otherClaudeLinkIsAcceptedAsAFallback() {
        let raw = "Sign in at https://claude.ai/connect/abcdef\r\n\r\n"
        #expect(SetupTokenParser.parse(raw).signInURL?.absoluteString == "https://claude.ai/connect/abcdef")
    }

    @Test func latestSignInURLWins() {
        let raw = "https://claude.com/cai/oauth/authorize?state=first\r\n\r\nOAuth error\r\nhttps://claude.com/cai/oauth/authorize?state=second\r\n\r\n"
        #expect(SetupTokenParser.parse(raw).signInURL?.absoluteString == "https://claude.com/cai/oauth/authorize?state=second")
    }

    @Test func httpIsNotOffered() {
        #expect(SetupTokenParser.parse("http://claude.ai/oauth/authorize?x=1\r\n\r\n", finished: true).signInURL == nil)
    }

    // MARK: Prompts and errors

    @Test func promptVariants() {
        for line in ["Paste code here if prompted >", "Paste the code from your browser:", "Paste the authorisation code:", "PASTE CODE HERE"] {
            #expect(SetupTokenParser.parse(line + "\r\n").isPromptingForCode, "\(line)")
        }
        #expect(!SetupTokenParser.parse("Opening browser to sign in…\r\n").isPromptingForCode)
    }

    @Test func promptIsNotReportedOnceTheTokenIsShown() {
        let raw = CapturedSetupToken.wide + SetupTokenSamples.successFrame() + "\r\r\n"  // no erase: prompt still on screen
        let out = SetupTokenParser.parse(raw)
        #expect(out.token != nil)
        #expect(!out.isPromptingForCode)
    }

    @Test func browserFailureIsNotAnError() {
        let raw = "Failed to open browser automatically.\r\nBrowser didn't open? Use the url below to sign in\r\n"
        #expect(SetupTokenParser.parse(raw).errorMessage == nil)
    }

    @Test func errorVariants() {
        for line in ["Error: Request failed with status code 403", "OAuth error: invalid_grant",
                     "✗ Login failed", "Failed to authenticate: subscription required",
                     "setup-token creates a long-lived Claude.ai subscription token, which this policy does not permit."] {
            #expect(SetupTokenParser.parse(line + "\r\n").errorMessage == line, "\(line)")
        }
    }

    @Test func erasedErrorDoesNotCountWhileRunningButDoesOnceFinishedIfNothingElse() {
        let raw = "Error: something\r\n\u{1B}[1A\u{1B}[2K\u{1B}[GRetrying…\r\n"
        #expect(SetupTokenParser.parse(raw).errorMessage == nil)
        #expect(SetupTokenParser.parse(raw, finished: true).errorMessage == "Error: something")
    }

    @Test func statedValidityVariants() {
        let cases: [(String, TimeInterval?)] = [
            ("valid for 1 year", 365 * 86_400), ("valid for 365 days", 365 * 86_400), ("valid for 12 months", 360 * 86_400),
            ("valid for a year", 365 * 86_400), ("valid for 2 weeks", 14 * 86_400), ("valid for ever", nil),
        ]
        for (text, expected) in cases {
            #expect(SetupTokenParser.parse("Your OAuth token (\(text)):\r\n").statedValidity == expected, "\(text)")
        }
    }

    @Test func emptyOutput() {
        let out = SetupTokenParser.parse("", finished: true)
        #expect(out == SetupTokenOutput())
        #expect(!out.hasVisibleText)
    }
}
