import Foundation

/// The bits of the file system `ClaudeLocator` needs, so tests can fake them.
public protocol FileSystem: Sendable {
    var homeDirectory: URL { get }
    /// True when `path` is a regular file (after following symlinks) that we may execute.
    func isExecutableFile(atPath path: String) -> Bool
    /// Names in a directory, or [] when it doesn't exist or can't be read.
    func contentsOfDirectory(atPath path: String) -> [String]
}

/// The real file system.
public struct LocalFileSystem: FileSystem {
    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    public func contentsOfDirectory(atPath path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}

/// A Claude Code version such as 2.1.300.
public struct ClaudeVersion: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Finds the first `x.y.z` in text such as `2.1.300 (Claude Code)`.
    public init?(parsing text: String) {
        guard let match = text.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3) else { return nil }
        self.init(major, minor, patch)
    }

    public static func < (lhs: ClaudeVersion, rhs: ClaudeVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// A `claude` binary that was found and whose version was read.
public struct ClaudeInstallation: Sendable, Hashable, Codable {
    public var url: URL
    public var version: ClaudeVersion

    public init(url: URL, version: ClaudeVersion) {
        self.url = url
        self.version = version
    }

    public var meetsMinimum: Bool { version >= ClaudeLocator.minimumVersion }
}

public enum ClaudeLocatorError: Error, Sendable, Hashable {
    /// No `claude` anywhere we looked. `searched` lists the paths tried, for the install sheet's details.
    case notFound(searched: [String])
    /// `claude --version` failed or printed something we couldn't read.
    case versionUnreadable(path: String, output: String)
    /// Found, but older than `ClaudeLocator.minimumVersion`.
    case tooOld(path: String, found: ClaudeVersion, minimum: ClaudeVersion)
}

/// Finds the `claude` binary. Apps opened from Finder don't get the shell's PATH, so this checks the usual install
/// locations in a fixed order and only then asks the user's login shell.
public struct ClaudeLocator: Sendable {
    /// The oldest Claude Code devshout supports. The one place to change it.
    public static let minimumVersion = ClaudeVersion(2, 1, 0)

    public var fileSystem: FileSystem
    public var runner: ProcessRunner
    /// A path the user picked in Settings. Tried first.
    public var userOverride: URL?
    /// The user's login shell (`$SHELL`), used as the last resort.
    public var shell: String?
    public var shellTimeout: TimeInterval
    public var versionTimeout: TimeInterval
    public var minimumVersion: ClaudeVersion

    public init(fileSystem: FileSystem = LocalFileSystem(),
                runner: ProcessRunner = FoundationProcessRunner(),
                userOverride: URL? = nil,
                shell: String? = ProcessInfo.processInfo.environment["SHELL"],
                shellTimeout: TimeInterval = 3,
                versionTimeout: TimeInterval = 10,
                minimumVersion: ClaudeVersion = ClaudeLocator.minimumVersion) {
        self.fileSystem = fileSystem
        self.runner = runner
        self.userOverride = userOverride
        self.shell = shell
        self.shellTimeout = shellTimeout
        self.versionTimeout = versionTimeout
        self.minimumVersion = minimumVersion
    }

    /// The fixed places to look, in order (the login-shell lookup comes after these).
    public func candidatePaths() -> [String] {
        let home = fileSystem.homeDirectory.path
        var paths: [String] = []
        if let userOverride { paths.append(userOverride.path) }
        paths += [
            "\(home)/.local/bin/claude",          // native installer
            "/opt/homebrew/bin/claude",           // Homebrew cask (Apple Silicon)
            "/usr/local/bin/claude",              // Homebrew cask (Intel) or a manual link
            "\(home)/.claude/local/claude",       // old local npm install
        ]
        paths += nvmCandidates(home: home)
        paths.append("\(home)/.npm-global/bin/claude")
        return paths
    }

    /// `~/.nvm/versions/node/*/bin/claude`, newest Node first.
    private func nvmCandidates(home: String) -> [String] {
        let root = "\(home)/.nvm/versions/node"
        let versions = fileSystem.contentsOfDirectory(atPath: root).sorted { lhs, rhs in
            switch (ClaudeVersion(parsing: lhs), ClaudeVersion(parsing: rhs)) {
            case let (l?, r?): l > r
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs > rhs
            }
        }
        return versions.map { "\(root)/\($0)/bin/claude" }
    }

    /// The first executable `claude`, or nil.
    public func findExecutable() async -> URL? {
        for path in candidatePaths() where fileSystem.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return await askLoginShell()
    }

    /// `$SHELL -l -c 'command -v claude'`, so a PATH set up in the user's profile is honoured.
    func askLoginShell() async -> URL? {
        guard let shell, !shell.isEmpty, fileSystem.isExecutableFile(atPath: shell) else { return nil }
        let home = fileSystem.homeDirectory.path
        let host = ProcessInfo.processInfo.environment
        var environment = [
            "HOME": home,
            "SHELL": shell,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": host["LANG"] ?? "en_GB.UTF-8",
        ]
        if let user = host["USER"] { environment["USER"] = user; environment["LOGNAME"] = user }
        let request = ProcessRequest(executable: URL(fileURLWithPath: shell),
                                     arguments: ["-l", "-c", "command -v claude"],
                                     environment: environment,
                                     currentDirectory: fileSystem.homeDirectory,
                                     timeout: shellTimeout)
        guard let result = try? await runner.run(request), !result.timedOut, result.exitCode == 0 else { return nil }
        // Profiles sometimes print things; the answer is the last line that is an absolute path.
        let path = result.stdoutString
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
        guard let path, fileSystem.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Runs `claude --version` and parses it.
    public func version(of executable: URL) async throws -> ClaudeVersion {
        let directory = executable.deletingLastPathComponent().path
        let request = ProcessRequest(
            executable: executable,
            arguments: ["--version"],
            environment: [
                "HOME": fileSystem.homeDirectory.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:\(directory)",
                "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_GB.UTF-8",
                "DISABLE_AUTOUPDATER": "1",
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            ],
            currentDirectory: nil,
            timeout: versionTimeout)
        let output: String
        do {
            let result = try await runner.run(request)
            output = result.stdoutString + result.stderrString
            if result.exitCode == 0, !result.timedOut, let version = ClaudeVersion(parsing: result.stdoutString) {
                return version
            }
        } catch {
            output = String(describing: error)
        }
        throw ClaudeLocatorError.versionUnreadable(path: executable.path, output: output)
    }

    /// Finds `claude`, reads its version and checks it against `minimumVersion`.
    public func locate() async throws -> ClaudeInstallation {
        guard let url = await findExecutable() else {
            var searched = candidatePaths()
            if let shell { searched.append("\(shell) -l -c 'command -v claude'") }
            throw ClaudeLocatorError.notFound(searched: searched)
        }
        let version = try await version(of: url)
        guard version >= minimumVersion else {
            throw ClaudeLocatorError.tooOld(path: url.path, found: version, minimum: minimumVersion)
        }
        return ClaudeInstallation(url: url, version: version)
    }
}

/// Remembers the located installation so a clean-up doesn't search every time. Call `invalidate()` after a run
/// fails in a way that suggests the binary moved, or when the user changes the path in Settings.
public actor ClaudeInstallationCache {
    private var locator: ClaudeLocator
    private var cached: ClaudeInstallation?

    public init(locator: ClaudeLocator) {
        self.locator = locator
    }

    public func installation() async throws -> ClaudeInstallation {
        if let cached { return cached }
        let found = try await locator.locate()
        cached = found
        return found
    }

    /// The cached value without searching.
    public var current: ClaudeInstallation? { cached }

    public func invalidate() { cached = nil }

    public func setUserOverride(_ url: URL?) {
        locator.userOverride = url
        cached = nil
    }
}
