import Foundation

/// How the saved `claude setup-token` token is doing. Tokens last a year and can't be renewed silently
/// (there is no refresh token), so devshout warns from 30 days before the end.
public enum TokenHealth: Sendable, Hashable {
    case ok
    case expiringSoon(daysLeft: Int)
    case expired

    public static let day: TimeInterval = 86_400
    /// `claude setup-token` makes one-year tokens.
    public static let lifetime: TimeInterval = 365 * day
    /// Warn from this long before the token runs out.
    public static let warningWindow: TimeInterval = 30 * day

    public static func expiryDate(createdAt: Date) -> Date { createdAt.addingTimeInterval(lifetime) }

    /// Whole days left, rounded up (so "1" means less than a day). Zero or less once expired.
    public static func daysLeft(createdAt: Date, now: Date) -> Int {
        let remaining = expiryDate(createdAt: createdAt).timeIntervalSince(now)
        return remaining <= 0 ? 0 : Int((remaining / day).rounded(.up))
    }

    public static func evaluate(createdAt: Date, now: Date) -> TokenHealth {
        let remaining = expiryDate(createdAt: createdAt).timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        if remaining <= warningWindow { return .expiringSoon(daysLeft: daysLeft(createdAt: createdAt, now: now)) }
        return .ok
    }

    public static func evaluate(_ credential: ClaudeCredential, now: Date) -> TokenHealth {
        evaluate(createdAt: credential.createdAt, now: now)
    }

    /// When the next check could change the answer (the start of the warning window, the next day boundary
    /// inside it, or the expiry itself). Handy for scheduling a timer.
    public static func nextChange(createdAt: Date, now: Date) -> Date? {
        let expiry = expiryDate(createdAt: createdAt)
        let warnFrom = expiry.addingTimeInterval(-warningWindow)
        if now < warnFrom { return warnFrom }
        if now >= expiry { return nil }
        let remaining = expiry.timeIntervalSince(now)
        let sinceBoundary = remaining.truncatingRemainder(dividingBy: day)
        return now.addingTimeInterval(sinceBoundary == 0 ? day : sinceBoundary)
    }

    /// "in 12 days", "within a day"
    public static func daysPhrase(_ days: Int) -> String {
        days <= 1 ? "within a day" : "in \(days) days"
    }
}

/// Why devshout needs the user to run the browser approval again.
public enum ReconnectReason: Sendable, Hashable {
    /// A year has passed since the token was made.
    case expired
    /// Claude refused the token (revoked, or expired early). `message` is what the CLI said, if anything.
    case authFailed(message: String)
}

/// The Claude connection as Settings, onboarding and the menu bar show it.
public enum ConnectionState: Sendable, Hashable {
    /// Not looked yet (launch).
    case checking
    /// No `claude` binary was found.
    case notInstalled
    /// Claude Code is installed but there is no token in the Keychain.
    case notConnected
    case connected(createdAt: Date, health: TokenHealth)
    case needsReconnect(reason: ReconnectReason)

    /// Works out the state from what was found. `authFailure` is set when a clean-up failed on authentication
    /// with the token that is saved now.
    public static func resolve(isInstalled: Bool, credential: ClaudeCredential?, authFailure: String?, now: Date) -> ConnectionState {
        guard isInstalled else { return .notInstalled }
        guard let credential else { return .notConnected }
        if let authFailure { return .needsReconnect(reason: .authFailed(message: authFailure)) }
        let health = TokenHealth.evaluate(credential, now: now)
        if health == .expired { return .needsReconnect(reason: .expired) }
        return .connected(createdAt: credential.createdAt, health: health)
    }

    /// Tidy and Structure can call Claude. When false they paste the raw text.
    public var canClean: Bool {
        if case .connected = self { return true }
        return false
    }

    /// The menu bar icon should show its attention badge.
    /// Not for `notInstalled` or `notConnected`: someone using Raw only shouldn't be nagged; onboarding covers it.
    public var needsAttention: Bool {
        switch self {
        case .needsReconnect: true
        case .connected(_, .expiringSoon): true
        default: false
        }
    }

    /// Short status for Settings → Claude and the onboarding step.
    public var title: String {
        switch self {
        case .checking: "Checking…"
        case .notInstalled: "Claude Code isn't installed"
        case .notConnected: "Not connected"
        case .connected(_, .ok): "Connected"
        case .connected(_, .expiringSoon(let days)): "Connected · token expires \(TokenHealth.daysPhrase(days))"
        case .connected(_, .expired): "Token expired"  // resolve() never produces this, but be safe
        case .needsReconnect(.expired): "Token expired"
        case .needsReconnect(.authFailed): "Needs reconnecting"
        }
    }

    /// A sentence or two under the title.
    public var detail: String {
        switch self {
        case .checking:
            return "Looking for Claude Code and your saved token."
        case .notInstalled:
            return "devshout uses Claude Code to tidy your dictation. Install it, then connect your Claude account. Raw mode works without it."
        case .notConnected:
            return "Connect your Claude account to use Tidy and Structure. It's a one-time approval in your browser; Raw mode works without it."
        case .connected(let createdAt, .ok):
            return "Clean-up uses your own Claude plan. Your token is valid until \(Self.formatDate(TokenHealth.expiryDate(createdAt: createdAt)))."
        case .connected(let createdAt, .expiringSoon):
            return "Your Claude token runs out on \(Self.formatDate(TokenHealth.expiryDate(createdAt: createdAt))). Reconnect before then to keep Tidy and Structure working; it takes a moment in your browser."
        case .connected(_, .expired), .needsReconnect(.expired):
            return "Your Claude token has run out (they last a year). Until you reconnect, Tidy and Structure paste the raw text."
        case .needsReconnect(.authFailed(let message)):
            let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let why = said.isEmpty ? "" : " Claude said: “\(said)”"
            return "Claude didn't accept the saved token. It may have been revoked or run out early.\(why) Until you reconnect, Tidy and Structure paste the raw text."
        }
    }

    /// The main button, if any.
    public var actionTitle: String? {
        switch self {
        case .checking: nil
        case .notInstalled: "Install Claude Code…"
        case .notConnected: "Connect…"
        case .connected(_, .ok): nil
        case .connected, .needsReconnect: "Reconnect…"
        }
    }

    /// A line for the menu bar menu when attention is needed.
    public var menuMessage: String? {
        switch self {
        case .connected(_, .expiringSoon(let days)): "Claude token expires \(TokenHealth.daysPhrase(days)): Reconnect…"
        case .needsReconnect(.expired): "Claude token expired: Reconnect…"
        case .needsReconnect(.authFailed): "Claude needs reconnecting…"
        default: nil
        }
    }

    /// The hint Tidy and Structure show when they paste raw because of the connection.
    public var rawFallbackHint: String? {
        switch self {
        case .checking, .connected: nil
        case .notInstalled: "Install Claude Code to tidy"
        case .notConnected: "Connect Claude to tidy"
        case .needsReconnect: "Reconnect Claude to tidy"
        }
    }

    /// "10 November 2027", in British style whatever the Mac's region.
    public static func formatDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }
}
