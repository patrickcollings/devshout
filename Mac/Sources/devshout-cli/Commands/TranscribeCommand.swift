// devshout-cli transcribe: one file through VAD → ChunkPlanner → engine → Stitcher → TextFixer, with timings.
//
// The pipeline itself is Core's SpikeTranscriber (tested on Linux with fakes); this file loads the real models.
// Unsure on macOS (written on Linux, type-checked there against stand-ins for DevshoutMac, never run on a Mac):
// - Nothing beyond what EngineHost (Support/Shared.swift) and the engines themselves list.
import ArgumentParser
import DevshoutCore
import DevshoutMac
import Foundation

struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe a recording with Parakeet or Whisper and print the text and timings.",
        discussion: """
        whole: Silero VAD and the chunk planner cut the file into chunks no longer than the engine takes \
        (Parakeet 14.5 s, Whisper 28 s), transcribed in order and stitched, as the app does after you stop. \
        live: the same chunks, timed as if they were transcribed while you were still talking (chunk i is ready \
        when the planner would have handed it over); reports the tail latency, the wait after you stop. \
        single: the whole file in one engine call, no VAD. \
        The text goes to stdout; progress and timings go to stderr. The first run of an engine downloads its model.
        """
    )

    @Argument(help: "A WAV file (any sample rate; other formats macOS can read also work).")
    var input: String

    @Option(help: "parakeet or whisper.")
    var engine: EngineChoice

    @Option(help: "A glossary.md: gives Whisper its vocabulary prompt and fixes known mishearings in the text.")
    var glossary: String?

    @Option(help: "whole, live or single.")
    var mode: TranscribeModeChoice = .whole

    @Flag(help: "Print the result as JSON (text, chunks, timings) instead of plain text.")
    var json = false

    @Flag(name: .customLong("no-vocabulary-prompt"),
          help: "Don't give Whisper the glossary prompt (to measure whether it helps). Glossary fixes still apply.")
    var noVocabularyPrompt = false

    @Flag(help: "Live mode: really wait for each chunk's moment instead of simulating it (takes as long as the recording).")
    var realtime = false

    @Option(name: .customLong("chunk-config"),
            help: "A JSON file with ChunkPlannerConfig values to try (e.g. {\"cutSilence\": 0.5}); missing keys keep their defaults.")
    var chunkConfig: String?

    @Flag(help: "Also list every chunk (times, overlap, engine time, text) on stderr.")
    var chunks = false

    func validate() throws {
        if realtime, mode != .live { throw ValidationError("--realtime only works with --mode live.") }
    }

    mutating func run() async throws {
        let url = try Files.existing(input, what: "audio file")
        let loadedGlossary = try Files.glossary(glossary)
        let config = try Files.chunkConfig(chunkConfig)

        let samples = try readAudio(url)
        Console.error("Read \(url.lastPathComponent): \(SpikeFormat.clock(Double(samples.count) / Double(AudioFormat.sampleRate))) of audio.")

        let host = EngineHost()
        let load = try await host.prepare(engine.id)
        let vadLoad = mode == .single ? nil : try await host.prepareVAD()

        let options = SpikeTranscriptionOptions(mode: mode.mode, glossary: loadedGlossary?.glossary,
                                                useVocabularyPrompt: !noVocabularyPrompt, plannerConfig: config,
                                                realTime: realtime)
        if realtime { Console.error("Replaying the recording in real time…") }
        var result: SpikeTranscriptionResult
        do {
            result = try await host.transcribe(samples: samples, engine: engine.id, options: options, audioFile: url.path)
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError("Transcription failed: \(error.localizedDescription)")
        }
        result.timings.modelLoad = load.seconds
        result.timings.modelDownloaded = load.downloaded
        result.timings.vadLoad = vadLoad
        await host.unloadAll()

        if json {
            Console.out(try result.jsonString())
        } else {
            Console.out(result.text)
        }
        Console.error("")
        if let loadedGlossary { Console.error("Glossary: \(loadedGlossary.url.path) (\(loadedGlossary.glossary.countsSummary))") }
        if engine == .whisper, loadedGlossary != nil, noVocabularyPrompt { Console.error("Whisper prompt: off (--no-vocabulary-prompt)") }
        for line in result.timingLines { Console.error(line) }
        if chunks { Self.printChunks(result) }
    }

    static func printChunks(_ result: SpikeTranscriptionResult) {
        Console.error("")
        Console.error("Chunks (seconds from the start of the recording):")
        for chunk in result.chunks {
            var line = String(format: "  #%d  %6.2f–%6.2f (%5.2f s)", chunk.index, chunk.start, chunk.end, chunk.duration)
            if chunk.overlapBefore > 0 { line += String(format: "  overlap %.2f s", chunk.overlapBefore) }
            line += String(format: "  ready at %6.2f", chunk.availableAt)
            if let started = chunk.startedAt, let finished = chunk.finishedAt {
                line += String(format: "  transcribed %6.2f–%6.2f", started, finished)
            }
            line += "  engine \(SpikeFormat.seconds(chunk.elapsed))"
            Console.error(line)
            Console.error("      \(chunk.text)")
        }
    }
}
