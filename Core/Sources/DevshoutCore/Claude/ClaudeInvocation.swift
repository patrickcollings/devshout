import Foundation

/// The parts of devshout's own environment the `claude` child may see. Everything else is left out on purpose.
public struct ClaudeHostEnvironment: Sendable, Hashable {
    public var home: String
    public var user: String?
    public var lang: String
    public var tmpDir: String

    public init(home: String, user: String?, lang: String = "en_GB.UTF-8", tmpDir: String) {
        self.home = home
        self.user = user
        self.lang = lang
        self.tmpDir = tmpDir
    }

    /// Read from this process. Apps opened from Finder often have no LANG, so British English UTF-8 is the default.
    public static var current: ClaudeHostEnvironment {
        let env = ProcessInfo.processInfo.environment
        let lang = env["LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "en_GB.UTF-8"
        let tmp = env["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return ClaudeHostEnvironment(home: env["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
                                     user: env["USER"] ?? env["LOGNAME"],
                                     lang: lang,
                                     tmpDir: tmp)
    }
}

/// Builds the `claude -p` call for one clean-up (PLAN §5.1). Pure: no files are touched here.
///
/// Never uses `--bare`: bare mode ignores `CLAUDE_CODE_OAUTH_TOKEN`, so it can't use a subscription.
public struct ClaudeInvocation: Sendable, Hashable {
    public enum SystemPrompt: Sendable, Hashable {
        /// `--system-prompt-file <url>`; the caller writes the file and deletes it afterwards.
        case file(URL)
        /// `--system-prompt <text>`.
        case inline(String)
    }

    /// The environment variables `claude` adds for us. Kept as a list so tests can check them.
    public static let fixedEnvironment: [String: String] = [
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
        "CLAUDE_CODE_SKIP_PROMPT_HISTORY": "1",
        "DISABLE_AUTOUPDATER": "1",
    ]

    /// Never passed to `claude`: any of them would move auth (and billing) off the user's subscription token.
    public static let forbiddenEnvironmentKeys: Set<String> = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
    public static let forbiddenEnvironmentPrefixes: [String] = ["CLAUDE_CODE_USE_"]

    public static let basePath = "/usr/bin:/bin:/usr/sbin:/sbin"

    public var executable: URL
    /// More folders for PATH (`ClaudeInstallation.extraPath`).
    public var extraPath: [String]
    public var model: String
    public var systemPrompt: SystemPrompt
    /// The stdin message (`PromptBuilder.userMessage`).
    public var stdin: String
    public var credential: ClaudeCredential
    /// devshout's own, empty `CLAUDE_CONFIG_DIR`. Nil leaves the variable unset (the user's own `~/.claude`).
    public var configDirectory: URL?
    /// An empty folder, so no project settings, `.mcp.json` or CLAUDE.md are found.
    public var workingDirectory: URL
    public var host: ClaudeHostEnvironment
    public var timeout: TimeInterval?

    public init(executable: URL, model: String, systemPrompt: SystemPrompt, stdin: String,
                credential: ClaudeCredential, configDirectory: URL?, workingDirectory: URL,
                host: ClaudeHostEnvironment = .current, timeout: TimeInterval? = nil, extraPath: [String] = []) {
        self.executable = executable
        self.extraPath = extraPath
        self.model = model
        self.systemPrompt = systemPrompt
        self.stdin = stdin
        self.credential = credential
        self.configDirectory = configDirectory
        self.workingDirectory = workingDirectory
        self.host = host
        self.timeout = timeout
    }

    public var arguments: [String] {
        var args = ["-p", PromptBuilder.userPrompt]
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { args += ["--model", model] }
        switch systemPrompt {
        case .file(let url): args += ["--system-prompt-file", url.path]
        case .inline(let text): args += ["--system-prompt", text]
        }
        args += [
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "user",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--max-turns", "1",
            "--output-format", "json",
        ]
        return args
    }

    /// Built from scratch: nothing from devshout's own environment leaks through except what is listed here.
    public var environment: [String: String] {
        var env = Self.fixedEnvironment
        env["HOME"] = host.home
        if let user = host.user, !user.isEmpty { env["USER"] = user }
        env["LANG"] = host.lang
        env["TMPDIR"] = host.tmpDir
        env["PATH"] = Self.path(for: executable, extraPath: extraPath)
        if let configDirectory { env["CLAUDE_CONFIG_DIR"] = configDirectory.path }
        env["CLAUDE_CODE_OAUTH_TOKEN"] = credential.token
        return Self.scrubbed(env)
    }

    /// The system folders, then claude's own folder, then `extraPath`, without repeats.
    public static func path(for executable: URL, extraPath: [String] = []) -> String {
        var directories = basePath.split(separator: ":").map(String.init)
        for directory in [executable.deletingLastPathComponent().path] + extraPath
            where !directory.isEmpty && !directories.contains(directory) {
            directories.append(directory)
        }
        return directories.joined(separator: ":")
    }

    /// Drops keys that must never reach `claude`.
    public static func scrubbed(_ env: [String: String]) -> [String: String] {
        env.filter { key, _ in
            !forbiddenEnvironmentKeys.contains(key) && !forbiddenEnvironmentPrefixes.contains { key.hasPrefix($0) }
        }
    }

    public var processRequest: ProcessRequest {
        ProcessRequest(executable: executable, arguments: arguments, environment: environment,
                       currentDirectory: workingDirectory, stdin: Data(stdin.utf8), timeout: timeout)
    }
}
