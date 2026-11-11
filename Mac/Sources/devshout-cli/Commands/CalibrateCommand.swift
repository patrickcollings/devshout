// devshout-cli calibrate: the app's "Calibrate your voice" analysis on a folder of recordings, for checking it end
// to end without a microphone (the recordings can be synthetic speech from `say`).
//
// The analysis, the recommendation and the learned corrections are Core's (CalibrationAnalyser, CalibrationLearning,
// CalibrationReport); this file loads the real engines and asks the Mac's spelling checker which words are ordinary.
import ArgumentParser
import DevshoutCore
import DevshoutMac
import Foundation

struct CalibrateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calibrate",
        abstract: "Benchmark the speech engines on recordings of known sentences, as the app's voice calibration does.",
        discussion: """
        Give it a folder of WAVs (c01.wav, c02.wav …) and the sentence each one says. The sentences come from \
        --sentences (one per line as "- c01: text"), by default <folder>/sentences.md, or else from a <name>.txt \
        beside each WAV. Every recording is transcribed with each engine whose model is downloaded (or the ones in \
        --engines), exactly as the app transcribes a dictation, and scored against its sentence: words right, \
        glossary terms spelled exactly right, and speed. Then it prints the recommendation and what the app would \
        offer to learn: mishearings of glossary terms, and notes about ordinary words.

        To try it with synthetic speech:
          devshout-cli calibrate --print-script --glossary bench/glossary.sample.md > /tmp/cal/sentences.md
          say -o /tmp/cal/c01.wav --data-format=LEI16@16000 "the first sentence"    (and so on)
          devshout-cli calibrate /tmp/cal --glossary bench/glossary.sample.md --details
        """
    )

    @Argument(help: "The folder of recordings (<id>.wav).")
    var folder: String?

    @Option(help: "The reference sentences, one per line as \"- <id>: text\". Default: <folder>/sentences.md, else <id>.txt beside each WAV.")
    var sentences: String?

    @Option(help: "A glossary.md: its terms are scored, fix the transcripts as in the app, and are what corrections are learned for.")
    var glossary: String?

    @Option(help: "Comma-separated: parakeet, whisper. Default: every engine whose model is downloaded.")
    var engines: String?

    @Flag(help: "Also print each sentence with what each engine wrote.")
    var details = false

    @Flag(name: .customLong("print-script"),
          help: "Print the script the app would show for --glossary (built-in sentences only: Claude isn't asked) and exit.")
    var printScript = false

    func validate() throws {
        if !printScript, folder == nil { throw ValidationError("Give the folder of recordings, or --print-script.") }
    }

    mutating func run() async throws {
        let loadedGlossary = try Files.glossary(glossary)
        let glossary = loadedGlossary?.glossary ?? .empty

        if printScript {
            Console.out(CalibrationScriptFile.render(CalibrationScriptBuilder.script(glossary: glossary)))
            return
        }

        let directory = try Files.existing(folder ?? "", what: "folder of recordings")
        let recordings = try Self.recordings(in: directory, sentencesPath: sentences,
                                             glossaryTerms: CalibrationScorer.glossaryTerms(glossary))
        guard !recordings.isEmpty else {
            throw CLIError("No recordings with a sentence in \(directory.path). Name them <id>.wav, with the sentences in sentences.md or <id>.txt.")
        }

        let locations = ModelLocations.default
        let chosen: [EngineID]
        if let engines {
            chosen = try engines.split(separator: ",").map { name -> EngineID in
                guard let choice = EngineChoice(rawValue: name.trimmingCharacters(in: .whitespaces)) else {
                    throw CLIError("Unknown engine \"\(name)\": use parakeet or whisper.")
                }
                return choice.id
            }
        } else {
            chosen = EngineID.allCases.filter { EngineFactory.isModelDownloaded($0, locations: locations) }
            guard !chosen.isEmpty else {
                throw CLIError("No speech model is downloaded. Download one in the app, or name one with --engines to download it now.")
            }
        }
        let notCompared = EngineID.allCases.filter { !chosen.contains($0) }

        Console.error("\(recordings.count) recordings, engines: \(CalibrationReport.engineList(chosen))"
                      + (loadedGlossary.map { ", glossary: \($0.url.lastPathComponent) (\($0.glossary.countsSummary))" } ?? ", no glossary"))

        let host = EngineHost()
        let options = SpikeTranscriptionOptions(mode: .whole, glossary: glossary)
        let analyser = CalibrationAnalyser(
            prepare: { engine in
                _ = try await host.prepare(engine)
                _ = try await host.prepareVAD()
            },
            transcribe: { recording, engine in
                let samples = try readAudio(recording.audioURL)
                let result = try await host.transcribe(samples: samples, engine: engine, options: options,
                                                       audioFile: recording.audioURL.path)
                return CalibrationTranscript(text: result.text, audioSeconds: result.audioDuration,
                                             processingSeconds: result.timings.transcribe)
            },
            release: { engine in await host.unload(engine) },
            describe: { error in (error as? CLIError)?.description ?? error.localizedDescription })
        let analysis = try await analyser.run(recordings: recordings, engines: chosen, glossary: glossary,
                                              progress: { step, _ in
            if case .transcribing(let engine, let done, let total) = step, done < total {
                Console.error("\(engine.shortName): recording \(done + 1) of \(total)")
            }
        })
        await host.unloadAll()

        // Which of the words the engines wrote are ordinary English words (the spelling checker is main-thread only).
        let words = CalibrationLearning.transcriptWords(analysis.observations)
        let ordinary = await MainActor.run { OrdinaryWords.ordinary(among: words) }
        let corrections = CalibrationLearning.corrections(observations: analysis.observations, glossary: glossary,
                                                          isOrdinaryWord: { ordinary.contains($0) })
        let styleNotes = CalibrationLearning.styleNotes(observations: analysis.observations, glossary: glossary)

        Console.error("")
        Console.out(CalibrationReport.text(sentences: recordings.map(\.sentence), analysis: analysis,
                                           corrections: corrections, styleNotes: styleNotes,
                                           notCompared: notCompared, details: details))
    }

    /// The recordings in `directory` that have a sentence, in id order.
    static func recordings(in directory: URL, sentencesPath: String?, glossaryTerms: [String]) throws -> [CalibrationRecording] {
        let fileManager = FileManager.default
        let files = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var script: [CalibrationSentence] = []
        let defaultFile = directory.appendingPathComponent("sentences.md")
        if let sentencesPath {
            let url = try Files.existing(sentencesPath, what: "sentences file")
            script = CalibrationScriptFile.parse(try String(contentsOf: url, encoding: .utf8), glossaryTerms: glossaryTerms)
        } else if fileManager.fileExists(atPath: defaultFile.path) {
            script = CalibrationScriptFile.parse(try String(contentsOf: defaultFile, encoding: .utf8), glossaryTerms: glossaryTerms)
        }

        var out: [CalibrationRecording] = []
        for file in files {
            let id = file.deletingPathExtension().lastPathComponent
            if let sentence = script.first(where: { $0.id == id }) {
                out.append(CalibrationRecording(sentence: sentence, audioURL: file))
                continue
            }
            let textFile = file.deletingPathExtension().appendingPathExtension("txt")
            if let text = try? String(contentsOf: textFile, encoding: .utf8),
               let sentence = CalibrationScriptFile.parse("\(id): " + text.split(whereSeparator: \.isNewline).joined(separator: " "),
                                                          glossaryTerms: glossaryTerms).first {
                out.append(CalibrationRecording(sentence: sentence, audioURL: file))
            } else {
                Console.error("Skipping \(file.lastPathComponent): no sentence for \"\(id)\".")
            }
        }
        return out
    }
}
