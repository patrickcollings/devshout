import ArgumentParser
import DevshoutCore
import DevshoutMac

/// Phase 0 spike tool: record, transcribe, clean up and benchmark from the command line.
/// Subcommands are added in Mac/Sources/devshout-cli/Commands/.
struct DevshoutCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devshout-cli",
        abstract: "devshout spike and benchmark tool.",
        version: DevshoutMac.version,
        subcommands: []
    )
}

await DevshoutCLI.main()
