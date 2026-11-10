// devshout-cli cleanup: raw text on stdin → ClaudeCLICleaner (claude -p, exactly as the app runs it) → stdout.
//
// Unsure on macOS (written on Linux, type-checked there against stand-ins for DevshoutMac, never run on a Mac):
// - The Keychain may ask once whether devshout-cli may read the token the app saved (a different binary made the
//   item); "Always Allow" sorts it. CLAUDE_CODE_OAUTH_TOKEN in the environment skips the Keychain.
import ArgumentParser
import DevshoutCore
import DevshoutMac
import Foundation

struct CleanupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Clean up a transcript from stdin with Claude (Tidy or Structure), as the app does.",
        discussion: """
        Runs `claude -p` on your Claude subscription with the token from `devshout-cli connect` (or \
        CLAUDE_CODE_OAUTH_TOKEN when set), in devshout's own empty config folder under \
        ~/Library/Application Support/devshout/. The cleaned text goes to stdout; timings and warnings to \
        stderr. If Claude fails, the reason is printed and the exit status is 1 (the app would paste the raw text).
        """
    )

    @Option(help: "tidy or structure.")
    var mode: CleanupModeChoice

    @Option(help: "Claude model alias or name. Default: haiku for tidy, sonnet for structure.")
    var model: String?

    @Option(help: "A glossary.md for Claude (spellings, names, mishearings).")
    var glossary: String?

    @Option(help: "Seconds to wait for Claude. Default: 20 for tidy, 45 for structure.")
    var timeout: Double?

    func validate() throws {
        if let timeout, !(timeout > 0) { throw ValidationError("--timeout must be more than 0.") }
        if let model, model.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError("--model can't be empty.") }
    }

    mutating func run() async throws {
        let raw = Console.readAllStdin(hint: "Type or paste the transcript, then press Ctrl-D on a new line.")
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError("Nothing on stdin to clean up. Pipe a transcript in: devshout-cli cleanup --mode tidy < raw.txt")
        }
        let loadedGlossary = try Files.glossary(glossary)
        let glossaryText = loadedGlossary.map { GlossaryRenderer.forClaude($0.glossary) } ?? ""

        let defaults = ModeConfig.defaults[mode.id] ?? ModeConfig(id: mode.id, claudeModel: "haiku", timeout: 30)
        let config = ModeConfig(id: mode.id, claudeModel: model ?? defaults.claudeModel,
                                timeout: timeout ?? defaults.timeout)
        let source = Credentials.environmentToken != nil ? "CLAUDE_CODE_OAUTH_TOKEN" : "the Keychain"
        Console.error("\(mode.id.displayName) with \(config.claudeModel), timeout \(SpikeFormat.seconds(config.timeout)), "
                      + "token from \(source)\(loadedGlossary.map { ", glossary \($0.url.lastPathComponent)" } ?? "")…")

        let started = SpikeClock.now()
        do {
            let result = try await ClaudeSetup.makeCleaner().clean(raw, mode: config, glossary: glossaryText)
            let total = SpikeClock.now() - started
            Console.out(result.text)
            Console.error("Claude (\(result.model)): \(SpikeFormat.seconds(result.elapsed)) from spawn to exit; "
                          + "\(SpikeFormat.seconds(total)) in all (finding claude, the Keychain, the prompt file).")
            Console.error("Words: \(TidyLengthCheck.wordCount(raw)) in, \(TidyLengthCheck.wordCount(result.text)) out.")
            for warning in result.warnings { Console.error("Warning: \(warning)") }
        } catch let error as CleanError {
            Console.error("Clean-up failed after \(SpikeFormat.seconds(SpikeClock.now() - started)): "
                          + CleanErrorText.describe(error))
            Console.error("(The app would paste the raw text.)")
            throw ExitCode.failure
        }
    }
}
