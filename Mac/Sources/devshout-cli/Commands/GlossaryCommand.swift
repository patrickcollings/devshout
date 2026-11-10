// devshout-cli glossary: what the parser makes of a glossary.md, what Claude is given, and Whisper's prompt.
//
// Unsure on macOS (written on Linux, type-checked there against stand-ins for DevshoutMac, never run on a Mac):
// - WhisperTokenCounter only gets WhisperKit's tokenizer once WhisperEngine has loaded the model, so with the model
//   downloaded this loads all of Whisper (several seconds) just to count tokens. --approximate skips that.
import ArgumentParser
import DevshoutCore
import DevshoutMac
import Foundation

struct GlossaryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "glossary",
        abstract: "Check a glossary.md: a summary, what Claude sees, and Whisper's vocabulary prompt."
    )

    @Argument(help: "The glossary file, e.g. bench/glossary.sample.md.")
    var file: String

    @Flag(help: "Count Whisper tokens with the approximate counter even when the Whisper model is downloaded.")
    var approximate = false

    @Option(name: .customLong("try"), help: "Some text to run the glossary fixes on, to see what they change.")
    var tryText: String?

    mutating func run() async throws {
        let url = try Files.existing(file, what: "glossary")
        let text = try GlossaryFile(url: url).loadText()
        let glossary = GlossaryParser.parse(text)

        Console.out("== Summary: \(url.lastPathComponent) ==")
        Console.out(GlossarySummary.render(glossary))

        Console.out("")
        Console.out("== What Claude sees (inside <glossary> in the system prompt) ==")
        let rendered = GlossaryRenderer.forClaude(glossary)
        Console.out(rendered.isEmpty ? "(nothing)" : rendered)

        var counter: any TokenCounter = ApproximateTokenCounter()
        var counterName = "the approximate counter (about 4 characters per token)"
        var engine: WhisperEngine?
        if approximate {
            counterName += ", as asked"
        } else if WhisperEngine.isDownloaded() {
            Console.error("Loading Whisper to count tokens with its own tokenizer (use --approximate to skip)…")
            let whisper = WhisperEngine()
            let printer = ProgressPrinter(label: EngineID.whisperLargeV3Turbo.displayName)
            do {
                try await whisper.prepare(progress: { printer.update($0) })
                printer.finish()
                if whisper.tokenCounter.usesWhisperTokenizer {
                    counter = whisper.tokenCounter
                    counterName = "WhisperKit's tokenizer"
                    engine = whisper
                } else {
                    counterName += " (Whisper loaded without its tokenizer)"
                }
            } catch {
                printer.finish()
                counterName += " (Whisper didn't load: \(error.localizedDescription))"
            }
        } else {
            counterName += " (the Whisper model isn't downloaded yet; any `transcribe --engine whisper` downloads it)"
        }

        let vocabulary = WhisperPromptBuilder(tokenCounter: counter).vocabulary(for: glossary)
        Console.out("")
        Console.out("== Whisper's vocabulary prompt ==")
        Console.out(vocabulary.prompt.isEmpty ? "(empty)" : vocabulary.prompt)
        Console.out("\(vocabulary.summary), counted by \(counterName).")
        let left = WhisperPromptBuilder.candidates(glossary).filter { !vocabulary.includedTerms.contains($0) }
        if !left.isEmpty { Console.out("Left out (over the budget): " + left.joined(separator: ", ")) }

        if let tryText {
            let fixed = TextFixer.fix(tryText, glossary: glossary)
            Console.out("")
            Console.out("== Glossary fixes on your text ==")
            Console.out(fixed.text)
            if fixed.replacements.isEmpty {
                Console.out("(no changes)")
            } else {
                for replacement in fixed.replacements {
                    Console.out("  \(replacement.original) → \(replacement.replacement) (\(replacement.kind.rawValue))")
                }
            }
        }
        if let engine { await engine.unload() }
    }
}
