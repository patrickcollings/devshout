import ArgumentParser
import DevshoutCore
import DevshoutMac

/// Phase 0 spike tool: record, transcribe, clean up and benchmark from the command line (PLAN §9).
/// Subcommands live in Commands/, shared helpers in Support/. The logic they run is in Core's Spike/ folder.
/// `@main` (not a main.swift with `await DevshoutCLI.main()`): in a main.swift, `DevshoutCLI.main()` resolves to
/// ParsableCommand's synchronous `main()`, which refuses an async root command at run time.
@main
struct DevshoutCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devshout-cli",
        abstract: "devshout spike and benchmark tool.",
        discussion: "See bench/README.md for the benchmark, step by step.",
        version: DevshoutMac.version,
        subcommands: [
            RecordCommand.self,
            TranscribeCommand.self,
            CleanupCommand.self,
            ConnectCommand.self,
            ClaudeProbeCommand.self,
            BenchCommand.self,
            GlossaryCommand.self,
        ]
    )
}
