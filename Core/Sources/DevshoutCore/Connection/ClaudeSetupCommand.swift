import Foundation

/// How devshout runs `claude setup-token`, and the `.command` scripts it hands to Terminal.
public enum ClaudeSetupCommand {
    public static let arguments = ["setup-token"]

    /// Terminal size for the PTY: wide enough that Ink never hard-wraps the token or the sign-in URL,
    /// tall enough that it never clears the screen to redraw.
    public static let columns: UInt16 = 4_000
    public static let rows: UInt16 = 200

    /// Variables that would move authentication away from the subscription or change where Claude Code
    /// keeps its state. None are passed (the environment is built from scratch), but `environment` also
    /// drops them from `extra`.
    public static let blockedVariables: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
    ]

    /// The complete environment for `claude setup-token` (nothing is inherited): HOME, USER, LANG, a PATH that
    /// starts with the binary's folder, TERM, and TMPDIR when known.
    public static func environment(claudeExecutable: URL, home: String, user: String, lang: String? = nil,
                                   tmpDir: String? = nil, extra: [String: String] = [:]) -> [String: String] {
        var env: [String: String] = [:]
        for (key, value) in extra where !blockedVariables.contains(key) { env[key] = value }
        env["HOME"] = home
        env["USER"] = user
        env["LOGNAME"] = user
        env["LANG"] = (lang?.isEmpty == false) ? lang : "en_GB.UTF-8"
        env["TERM"] = "xterm-256color"
        env["PATH"] = path(including: claudeExecutable.deletingLastPathComponent().path)
        if let tmpDir, !tmpDir.isEmpty { env["TMPDIR"] = tmpDir }
        return env
    }

    public static let systemPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// The binary's folder first (Claude Code may call itself), then the system folders, without duplicates.
    public static func path(including folder: String) -> String {
        var parts: [String] = []
        for p in [folder] + systemPath where !p.isEmpty && !parts.contains(p) { parts.append(p) }
        return parts.joined(separator: ":")
    }
}

/// Contents of `.command` files that devshout opens in Terminal, as the fallback for anything run in-app.
public enum TerminalScript {
    /// Anthropic's official installer, unmodified.
    public static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    /// The script `ClaudeInstaller` runs with `/bin/bash -c`: the official installer, unmodified, in the
    /// background, with a SIGTERM trap that stops it and everything it started. Without this, terminating the
    /// outer bash would leave `curl` and the inner `bash` running (bash doesn't exec a pipeline).
    public static var cancellableInstallScript: String { cancellable(installCommand) }

    /// `commandLine` in the background of a bash script whose SIGTERM (or INT/HUP) stops it and all its descendants.
    public static func cancellable(_ commandLine: String) -> String {
        """
        killtree() { local c; for c in $(/usr/bin/pgrep -P "$1"); do killtree "$c"; done; kill -TERM "$1" 2>/dev/null; }
        trap 'for c in $(/usr/bin/pgrep -P $$); do killtree "$c"; done; exit 143' TERM INT HUP
        \(commandLine) &
        wait $!
        """
    }

    /// Quotes `s` for bash (single quotes, with embedded ones escaped).
    public static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-+:=@%,".contains($0)) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A bash script that deletes itself, prints `intro`, runs `commandLine`, then `outro` (or what went wrong).
    public static func commandFile(intro: String, commandLine: String, outro: String) -> String {
        """
        #!/bin/bash
        # Written by devshout. It deletes itself when it starts; nothing else is changed.
        rm -f -- "$0"
        clear
        printf '%s\\n\\n' \(shellQuote(intro))
        \(commandLine)
        status=$?
        echo
        if [ "$status" -eq 0 ]; then
          printf '%s\\n' \(shellQuote(outro))
        else
          printf '%s\\n' "That didn't work (exit code $status). Scroll up to see why, then try again."
        fi
        exit $status

        """
    }

    /// Installs Claude Code in Terminal.
    public static func installClaude() -> String {
        commandFile(
            intro: "Installing Claude Code with Anthropic's official installer (\(installCommand))…",
            commandLine: "/bin/bash -c \(shellQuote(installCommand))",
            outro: "Done. You can close this window and go back to devshout, which will find Claude Code by itself."
        )
    }

    /// Runs `claude setup-token` in Terminal, for when the in-app flow doesn't work.
    public static func setupToken(claudeExecutable: URL) -> String {
        commandFile(
            intro: "Connecting devshout to your Claude account. Approve access in your browser; the token appears here.",
            commandLine: "\(shellQuote(claudeExecutable.path)) setup-token",
            outro: "Copy the token (the line starting sk-ant-), then paste it into devshout: Settings → Claude → Paste a token."
        )
    }
}
