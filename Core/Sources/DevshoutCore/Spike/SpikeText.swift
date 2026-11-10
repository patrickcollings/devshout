import Foundation

/// The summary `devshout-cli glossary <file>` prints: what the parser found, section by section.
public enum GlossarySummary {
    public static func render(_ glossary: Glossary) -> String {
        var lines: [String] = []
        if let title = glossary.title { lines.append("Title: \(title)") }
        lines.append("Found: \(glossary.countsSummary)")
        lines.append("")
        lines.append("Sections:")
        if glossary.sections.isEmpty { lines.append("  (none)") }
        for section in glossary.sections {
            let name = section.heading.map { "## \($0)" } ?? "(before the first heading)"
            let notes = section.notes.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.count
            var parts: [String] = []
            if section.kind.holdsEntries {
                let entries = section.entries
                parts.append("\(entries.count) \(entries.count == 1 ? "entry" : "entries")")
                let heard = entries.reduce(0) { $0 + $1.heard.count }
                if heard > 0 { parts.append("\(heard) known \(heard == 1 ? "mishearing" : "mishearings")") }
            }
            if notes > 0 { parts.append("\(notes) \(notes == 1 ? "line" : "lines") of text") }
            if parts.isEmpty { parts.append("empty") }
            lines.append("  \(name) [\(section.kind.rawValue)]: " + parts.joined(separator: ", "))
        }

        let pinned = glossary.allEntries.filter { $0.entry.pinned }.map(\.entry.term)
        lines.append("")
        lines.append("Pinned (top of Whisper's list): " + (pinned.isEmpty ? "none" : pinned.joined(separator: ", ")))

        let patterns = glossary.patterns
        lines.append("Patterns: " + (patterns.isEmpty ? "none" : ""))
        for pattern in patterns {
            let heard = pattern.heard.isEmpty ? "" : " (heard: \(pattern.heard.joined(separator: ", ")))"
            let description = pattern.description.map { " — \($0)" } ?? ""
            lines.append("  \(pattern.term)\(description)\(heard)")
        }

        let mishearings = glossary.allEntries.filter { !$0.entry.isPattern && !$0.entry.heard.isEmpty }
        if !mishearings.isEmpty {
            lines.append("Mishearings fixed in every mode:")
            for item in mishearings {
                lines.append("  \(item.entry.heard.joined(separator: ", ")) → \(item.entry.term)")
            }
        }
        let style = glossary.styleText
        lines.append("Style notes: " + (style.isEmpty ? "none" : "\(style.split(separator: "\n").count) lines"))
        if glossary.isEffectivelyEmpty {
            lines.append("")
            lines.append("This glossary has nothing devshout would use (everything is empty or commented out).")
        }
        return lines.joined(separator: "\n")
    }
}

/// A token pasted into `devshout-cli connect`.
public enum SpikeTokenInput {
    /// The bare token from what was pasted: a token on its own (with the clean-up `ClaudeTokenFormat` does), or
    /// the whole output of `claude setup-token` copied from Terminal. API keys are refused.
    public static func token(from input: String) throws -> String {
        do {
            return try ClaudeTokenFormat.validate(input)
        } catch {
            let parsed = SetupTokenParser.parse(input, finished: true)
            if let token = parsed.token, let valid = try? ClaudeTokenFormat.validate(token) { return valid }
            throw SpikeError.invalidInput(error.message)
        }
    }

    /// A creation date typed as "2026-11-10" (midnight in `timeZone`).
    public static func date(fromDay text: String, timeZone: TimeZone = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }
}

/// `devshout-cli connect --status`.
public enum SpikeConnectionReport {
    public enum CredentialSource: String, Sendable {
        case keychain = "Keychain"
        case environment = "CLAUDE_CODE_OAUTH_TOKEN"
    }

    public static func render(installation: ClaudeInstallation?, installationError: String?,
                              credential: ClaudeCredential?, source: CredentialSource?, keychainError: String?,
                              authFailure: String?, homeDirectory: String, now: Date = Date(),
                              timeZone: TimeZone = .current) -> String {
        let state = ConnectionState.resolve(isInstalled: installation != nil, credential: credential,
                                            authFailure: authFailure, now: now)
        var lines: [String] = ["Status: \(state.title)", state.detail, ""]
        if let installation {
            lines.append("Claude Code: \(installation.summary(homeDirectory: homeDirectory))")
            if !installation.extraPath.isEmpty { lines.append("Extra PATH: \(installation.extraPath.joined(separator: ":"))") }
        } else {
            lines.append("Claude Code: not found" + (installationError.map { " (\($0))" } ?? ""))
        }
        if let credential {
            lines.append("Token: \(SpikeFormat.maskedToken(credential.token)), from \(source?.rawValue ?? "?")")
            let expiry = TokenHealth.expiryDate(createdAt: credential.createdAt)
            lines.append("Created: \(ConnectionState.formatDate(credential.createdAt, timeZone: timeZone)) · "
                         + "expires: \(ConnectionState.formatDate(expiry, timeZone: timeZone))")
            switch TokenHealth.evaluate(credential, now: now) {
            case .ok:
                lines.append("Health: OK, \(TokenHealth.daysLeft(createdAt: credential.createdAt, now: now)) days left")
            case .expiringSoon(let days):
                lines.append("Health: expiring \(TokenHealth.daysPhrase(days)); run `claude setup-token` and `devshout-cli connect` again")
            case .expired:
                lines.append("Health: expired; run `claude setup-token` and `devshout-cli connect` again")
            }
            if source == .environment {
                lines.append("(A token from the environment has no known creation date, so the dates above assume it was made today.)")
            }
        } else {
            lines.append("Token: none stored" + (keychainError.map { " (\($0))" } ?? ""))
        }
        if let authFailure { lines.append("Last clean-up failed on authentication: \(authFailure)") }
        return lines.joined(separator: "\n")
    }
}
