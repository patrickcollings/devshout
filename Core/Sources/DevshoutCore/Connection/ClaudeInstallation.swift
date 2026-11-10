import Foundation

/// Display helpers for the `ClaudeInstallation` found by `ClaudeLocator`.
extension ClaudeInstallation {
    /// "Claude Code 2.1.322 (~/.local/bin/claude)" for Settings.
    public func summary(homeDirectory: String) -> String {
        var path = url.path
        if !homeDirectory.isEmpty, path.hasPrefix(homeDirectory + "/") { path = "~" + path.dropFirst(homeDirectory.count) }
        return "Claude Code \(displayVersion) (\(path))"
    }

    /// "2.1.322".
    public var displayVersion: String { version.description }
}

/// A clean-up failure on authentication, remembered against the token it happened with, so a new token
/// clears it and a relaunch doesn't forget it.
public struct ClaudeAuthFailure: Codable, Sendable, Hashable {
    /// `createdAt` of the credential that was refused.
    public var credentialCreatedAt: Date
    public var message: String

    public init(credentialCreatedAt: Date, message: String) {
        self.credentialCreatedAt = credentialCreatedAt
        self.message = message
    }

    /// The message, if this failure is about `credential`.
    public func message(for credential: ClaudeCredential?) -> String? {
        guard let credential, credential.createdAt == credentialCreatedAt else { return nil }
        return message
    }
}
