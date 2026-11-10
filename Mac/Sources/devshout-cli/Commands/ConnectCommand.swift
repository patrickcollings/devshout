// devshout-cli connect: save a `claude setup-token` token in the Keychain item the app uses, show its status, or
// remove it. (The app runs setup-token in a pseudo-terminal itself; for the spike, the user runs it in Terminal.)
//
// Unsure on macOS (written on Linux, type-checked there against stand-ins for DevshoutMac, never run on a Mac):
// - The Keychain item made by devshout-cli names devshout-cli in its access list, so the app may ask once to read
//   it (and the other way round). "Always Allow" sorts it.
// - Terminal's canonical input limit (1,024 bytes on macOS) is far above a token's ~108 characters, so a pasted
//   token arrives whole with echo off.
import ArgumentParser
import DevshoutCore
import DevshoutMac
import Foundation

struct ConnectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Save your Claude token (from `claude setup-token`) in the Keychain, or show or remove it.",
        discussion: """
        The token is kept only in this Mac's Keychain (service \(KeychainCredentialStore.defaultService)), \
        the same item the app reads. There is no API-key option: clean-up runs on your Claude subscription.
        """
    )

    @Flag(help: "Show whether Claude Code is installed and a token is saved, and when it expires.")
    var status = false

    @Flag(help: "Remove the saved token from the Keychain.")
    var delete = false

    @Option(help: "The day the token was made (yyyy-mm-dd), if not today, so expiry warnings are right.")
    var created: String?

    func validate() throws {
        if status, delete { throw ValidationError("Use --status or --delete, not both.") }
        if let created, SpikeTokenInput.date(fromDay: created) == nil {
            throw ValidationError("--created takes a date like 2026-11-10.")
        }
        if created != nil, status || delete { throw ValidationError("--created is only for saving a token.") }
    }

    mutating func run() async throws {
        let store = KeychainCredentialStore()
        if delete {
            do {
                try store.delete()
            } catch {
                throw CLIError(error.localizedDescription)
            }
            Console.out("Removed the Claude token from the Keychain. Tidy and Structure will paste the raw text until you connect again.")
            return
        }
        if status {
            await Self.printStatus()
            return
        }

        Console.error("""
        To connect devshout to your Claude subscription:
          1. In another Terminal window, run:  claude setup-token
          2. Approve the request in the browser page it opens (sign in to Claude if asked).
          3. Copy the token it prints (it starts sk-ant-oat) and paste it here.
        The token is saved only in this Mac's Keychain. It lasts a year.

        """)
        let input: String?
        if Console.stdinIsTerminal {
            input = Console.readSecretLine(prompt: "Token (hidden as you paste): ")
        } else {
            input = Console.readAllStdin()
        }
        guard let input, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError("No token was pasted, so nothing was saved.")
        }
        let token: String
        do {
            token = try SpikeTokenInput.token(from: input)
        } catch {
            throw CLIError("\(error) Nothing was saved.")
        }
        let createdAt = created.flatMap { SpikeTokenInput.date(fromDay: $0) } ?? Date()
        do {
            try store.save(ClaudeCredential(token: token, createdAt: createdAt))
        } catch {
            throw CLIError(error.localizedDescription)
        }
        Console.error("Saved \(SpikeFormat.maskedToken(token)) in the Keychain.")
        if Credentials.environmentToken != nil {
            Console.error("Note: CLAUDE_CODE_OAUTH_TOKEN is set in this shell, and devshout-cli uses it instead of the Keychain.")
        }
        Console.error("")
        await Self.printStatus()
    }

    static func printStatus() async {
        let found = await ClaudeSetup.locate()
        let current = Credentials.current()
        let report = SpikeConnectionReport.render(installation: found.installation, installationError: found.error,
                                                  credential: current.credential, source: current.source,
                                                  keychainError: current.error,
                                                  authFailure: Credentials.appAuthFailure(for: current.credential),
                                                  homeDirectory: NSHomeDirectory())
        Console.out(report)
    }
}
