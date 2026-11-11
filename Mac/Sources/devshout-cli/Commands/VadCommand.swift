// devshout-cli vad: the voice-activity probability of every frame of a recording, for tuning the chunk planner.
import ArgumentParser
import DevshoutCore
import DevshoutMac
import Foundation

struct VadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vad",
        abstract: "Print Silero's speech probability for each 256 ms frame of a recording."
    )

    @Argument(help: "A WAV file (any sample rate; other formats macOS can read also work).")
    var input: String

    mutating func run() async throws {
        let url = try Files.existing(input, what: "recording")
        let samples = try readAudio(url)
        let vad = SileroVAD()
        try await vad.prepare()
        var probabilities = try await vad.process(samples)
        if let last = try await vad.processRemainder() { probabilities.append(last) }

        let config = ChunkPlannerConfig.default
        let frame = Double(samples.count) / Double(AudioFormat.sampleRate) / Double(max(1, probabilities.count))
        Console.out(String(format: "%d frames of about %.3f s. Speech starts at %.2f and ends below %.2f.",
                           probabilities.count, frame, config.speechThreshold, config.speechExitThreshold))
        for (index, probability) in probabilities.enumerated() {
            let bar = String(repeating: "#", count: Int((probability * 40).rounded()))
            Console.out(String(format: "%7.2f s  %.2f  %@", Double(index) * frame, probability, bar))
        }
    }
}
