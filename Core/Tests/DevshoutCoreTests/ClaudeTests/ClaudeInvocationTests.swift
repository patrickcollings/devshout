import Foundation
import Testing
@testable import DevshoutCore

@Suite struct ClaudeInvocationTests {
    let claude = URL(fileURLWithPath: "/Users/sam/.local/bin/claude")
    let config = URL(fileURLWithPath: "/Users/sam/Library/Application Support/devshout/claude")
    let cwd = URL(fileURLWithPath: "/Users/sam/Library/Application Support/devshout/claude-cwd")
    let promptFile = URL(fileURLWithPath: "/var/folders/xy/T/devshout-system.md")

    func invocation(model: String = "haiku", systemPrompt: ClaudeInvocation.SystemPrompt? = nil,
                    configDirectory: URL?? = .none, host: ClaudeHostEnvironment = ClaudeTestSupport.host) -> ClaudeInvocation {
        ClaudeInvocation(executable: claude, model: model, systemPrompt: systemPrompt ?? .file(promptFile),
                         stdin: "<transcript>\nhello\n</transcript>\n", credential: ClaudeTestSupport.credential,
                         configDirectory: configDirectory ?? config, workingDirectory: cwd, host: host, timeout: 20)
    }

    @Test func exactArguments() {
        #expect(invocation().arguments == [
            "-p", "Clean up the transcript on stdin following your instructions. Output only the result.",
            "--model", "haiku",
            "--system-prompt-file", "/var/folders/xy/T/devshout-system.md",
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "user",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--max-turns", "1",
            "--output-format", "json",
        ])
    }

    @Test func inlineSystemPromptAndOtherModel() {
        let args = invocation(model: "sonnet", systemPrompt: .inline("Be brief.")).arguments
        #expect(args[2...5] == ["--model", "sonnet", "--system-prompt", "Be brief."])
        #expect(!args.contains("--system-prompt-file"))
    }

    @Test func emptyModelIsLeftOut() {
        #expect(!invocation(model: " ").arguments.contains("--model"))
    }

    @Test func neverBare() {
        for model in ["haiku", "sonnet", "opus"] {
            #expect(!invocation(model: model).arguments.contains("--bare"))
        }
    }

    @Test func exactEnvironment() {
        #expect(invocation().environment == [
            "HOME": "/Users/sam",
            "USER": "sam",
            "LANG": "en_GB.UTF-8",
            "TMPDIR": "/var/folders/xy/T/",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/Users/sam/.local/bin",
            "CLAUDE_CONFIG_DIR": "/Users/sam/Library/Application Support/devshout/claude",
            "CLAUDE_CODE_OAUTH_TOKEN": "fake-token-for-tests",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
            "CLAUDE_CODE_SKIP_PROMPT_HISTORY": "1",
            "DISABLE_AUTOUPDATER": "1",
        ])
    }

    @Test func configDirectoryCanBeLeftUnset() {
        let env = invocation(configDirectory: .some(nil)).environment
        #expect(env["CLAUDE_CONFIG_DIR"] == nil)
        #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == "fake-token-for-tests")
    }

    @Test func claudeInASystemDirectoryIsNotAddedTwice() {
        var inv = invocation()
        inv.executable = URL(fileURLWithPath: "/usr/bin/claude")
        #expect(inv.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func extraPathIsAppended() {
        var inv = invocation()
        inv.extraPath = ["/opt/homebrew/bin", "/usr/bin", "/opt/homebrew/bin"]
        #expect(inv.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin:/Users/sam/.local/bin:/opt/homebrew/bin")
    }

    @Test func forbiddenKeysAreScrubbed() {
        let scrubbed = ClaudeInvocation.scrubbed([
            "ANTHROPIC_API_KEY": "sk-ant-api", "ANTHROPIC_AUTH_TOKEN": "t", "CLAUDE_CODE_USE_BEDROCK": "1",
            "CLAUDE_CODE_USE_VERTEX": "1", "CLAUDE_CODE_USE_FOUNDRY": "1", "HOME": "/h",
        ])
        #expect(scrubbed == ["HOME": "/h"])
        let env = invocation().environment
        #expect(env.keys.allSatisfy { !$0.hasPrefix("ANTHROPIC_") && !$0.hasPrefix("CLAUDE_CODE_USE_") })
    }

    @Test func hostWithoutUserOmitsIt() {
        let host = ClaudeHostEnvironment(home: "/h", user: nil, tmpDir: "/t")
        let env = invocation(host: host).environment
        #expect(env["USER"] == nil)
        #expect(env["LANG"] == "en_GB.UTF-8")
    }

    @Test func processRequest() {
        let request = invocation().processRequest
        #expect(request.executable == claude)
        #expect(request.currentDirectory == cwd)
        #expect(request.stdin == Data("<transcript>\nhello\n</transcript>\n".utf8))
        #expect(request.timeout == 20)
        #expect(request.environment == invocation().environment)
    }

    @Test func currentHostDoesNotLeakEverything() {
        let host = ClaudeHostEnvironment.current
        #expect(!host.home.isEmpty)
        #expect(!host.lang.isEmpty)
        #expect(!host.tmpDir.isEmpty)
    }
}
