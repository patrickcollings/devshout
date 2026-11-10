// devshout-cli claude-probe: where claude is, and how long it takes to start, to clean up one sentence, and to
// clean it up when started early with its stdin left open (the pre-warm idea in PLAN §5.1).
//
// Unsure on macOS (written on Linux, type-checked there against stand-ins for DevshoutMac, never run on a Mac):
// - Whether `claude -p` really does its start-up work before reading stdin; the pre-warm numbers answer that.
import ArgumentParser
import DevshoutCore
import DevshoutMac
import Foundation

struct ClaudeProbeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claude-probe",
        abstract: "Find claude and time its start-up, a minimal clean-up, and a pre-warmed clean-up.",
        discussion: """
        Times N runs each of: `claude --version` (pure start-up), a Tidy clean-up of one short sentence \
        (spawn → exit, exactly as the app runs it), and the same clean-up started early with its stdin open and \
        written after --prewarm-delay seconds (stdin written → exit). Clean-ups use your Claude subscription.
        """
    )

    @Option(help: "How many runs of each.")
    var runs = 10

    @Option(help: "The Claude model for the clean-up runs.")
    var model = "haiku"

    @Option(name: .customLong("prewarm-delay"),
            help: "Seconds a pre-warmed claude waits before its stdin is written (0 skips the pre-warmed runs).")
    var prewarmDelay: Double = 3

    @Flag(name: .customLong("skip-cleanups"), help: "Only time `claude --version` (no clean-ups, no subscription use).")
    var skipCleanups = false

    func validate() throws {
        guard runs >= 1 else { throw ValidationError("--runs must be at least 1.") }
        guard prewarmDelay >= 0 else { throw ValidationError("--prewarm-delay can't be negative.") }
    }

    mutating func run() async throws {
        let found = await ClaudeSetup.locate()
        guard let installation = found.installation else {
            throw CLIError(found.error ?? "claude wasn't found.")
        }
        Console.out("claude: \(installation.url.path)")
        Console.out("Version: \(installation.displayVersion)\(installation.meetsMinimum ? "" : " (older than devshout needs)")")
        Console.out("Extra PATH: \(installation.extraPath.isEmpty ? "none (a self-contained binary)" : installation.extraPath.joined(separator: ":"))")

        let current = Credentials.current()
        let keychain = (try? KeychainCredentialStore().load()) ?? nil
        if let keychain {
            Console.out("Token in the Keychain: yes, made \(ConnectionState.formatDate(keychain.createdAt)), "
                        + "\(TokenHealth.daysLeft(createdAt: keychain.createdAt, now: Date())) days left")
        } else {
            Console.out("Token in the Keychain: no" + (current.error.map { " (\($0))" } ?? ""))
        }
        if Credentials.environmentToken != nil { Console.out("CLAUDE_CODE_OAUTH_TOKEN: set (used instead of the Keychain)") }
        Console.out("Config folder: \(ClaudeSetup.paths.claudeConfigDirectory.path)")
        Console.out("")

        Console.error("Timing \(runs) × claude --version…")
        let version = await ClaudeProbe.time(ClaudeProbe.versionRequest(for: installation, home: NSHomeDirectory()), runs: runs)
        Self.report("claude --version (start-up)", version.times, failures: version.failures)

        guard !skipCleanups else { return }
        guard let credential = current.credential else {
            Console.out("Clean-ups skipped: no token. Run `devshout-cli connect` first.")
            return
        }

        let mode = ClaudeProbe.probeMode(model: model)
        Console.error("Timing \(runs) × a \(model) clean-up of: “\(ClaudeProbe.probeSentence)”…")
        let cleaner = ClaudeSetup.makeCleaner()
        var cold: [TimeInterval] = []
        var coldWall: [TimeInterval] = []
        var failures: [String] = []
        var example: String?
        for run in 1...runs {
            let started = SpikeClock.now()
            do {
                let result = try await cleaner.clean(ClaudeProbe.probeSentence, mode: mode, glossary: "")
                cold.append(result.elapsed)
                coldWall.append(SpikeClock.now() - started)
                if example == nil { example = result.text }
            } catch let error as CleanError {
                failures.append("run \(run): \(CleanErrorText.describe(error))")
                if case .timedOut = error { continue }
                if case .rejectedOutput = error { continue }
                break // no claude, no token or a refused token: the other runs would fail the same way
            }
        }
        Self.report("\(model) clean-up, cold (spawn → exit)", cold, failures: failures)
        if let all = TimingStats(coldWall) { Console.out("  with finding claude, the Keychain and the prompt file: \(all.summary)") }
        if let example { Console.out("  answer: \(example)") }

        guard prewarmDelay > 0, !cold.isEmpty else { return }
        Console.error("Timing \(runs) × the same clean-up pre-warmed (stdin written after \(SpikeFormat.seconds(prewarmDelay)))…")
        var warm: [TimeInterval] = []
        var warmFirstByte: [TimeInterval] = []
        var warmFailures: [String] = []
        var answeredEarly = false
        for run in 1...runs {
            do {
                let (request, promptFile) = try ClaudeProbe.cleanUpRequest(installation: installation,
                                                                           credential: credential, mode: mode,
                                                                           paths: ClaudeSetup.paths)
                defer { try? FileManager.default.removeItem(at: promptFile) }
                let child = try PrewarmedProcess.start(request)
                try await Task.sleep(nanoseconds: UInt64(prewarmDelay * 1_000_000_000))
                let measured = await child.finish(stdin: request.stdin ?? Data())
                if measured.outputBeforeWrite { answeredEarly = true }
                switch ClaudeResultParser.interpret(measured.result) {
                case .success:
                    warm.append(measured.afterWrite)
                    if let first = measured.firstByteAfterWrite { warmFirstByte.append(first) }
                case .failure(let error):
                    warmFailures.append("run \(run): \(measured.result.timedOut ? "timed out" : CleanErrorText.describe(error))")
                }
            } catch {
                warmFailures.append("run \(run): \(error)")
            }
        }
        Self.report("\(model) clean-up, pre-warmed (stdin written → exit)", warm, failures: warmFailures)
        if let first = TimingStats(warmFirstByte) { Console.out("  stdin written → first byte: \(first.summary)") }
        if answeredEarly { Console.out("  Note: claude wrote output before its stdin was written in some runs.") }
        if let coldStats = TimingStats(cold), let warmStats = TimingStats(warm) {
            let saved = coldStats.median - warmStats.median
            Console.out("")
            Console.out(saved > 0.1
                        ? "Pre-warming saves about \(SpikeFormat.seconds(saved)) per clean-up (median)."
                        : "Pre-warming saves nothing worth having (median difference \(SpikeFormat.seconds(saved))).")
        }
    }

    static func report(_ title: String, _ times: [TimeInterval], failures: [String]) {
        if let stats = TimingStats(times) {
            Console.out("\(title): \(stats.summary)")
        } else {
            Console.out("\(title): no successful runs")
        }
        for failure in failures { Console.out("  failed \(failure)") }
    }
}
