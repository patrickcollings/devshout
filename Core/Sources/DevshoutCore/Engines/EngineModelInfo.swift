import Foundation

// Facts about the models behind each engine: where they come from and roughly how big they are.
// Checked against FluidAudio 0.18.3, argmax-oss-swift 1.1.1 and the Hugging Face repo listings on 2026-11-10.

public extension EngineID {
    /// The Hugging Face repository the model is downloaded from.
    var modelRepository: String {
        switch self {
        case .parakeetV3: "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        case .whisperLargeV3Turbo: "argmaxinc/whisperkit-coreml"
        }
    }

    /// The model within the repository: FluidAudio's folder name for Parakeet, WhisperKit's variant for Whisper.
    var modelVariant: String {
        switch self {
        case .parakeetV3: "parakeet-tdt-0.6b-v3-coreml"
        case .whisperLargeV3Turbo: "openai_whisper-large-v3-v20240930_turbo_632MB"
        }
    }

    /// Approximate first-run download, in bytes, for the size shown before downloading.
    /// Parakeet: Preprocessor 0.5 MB + Encoder 446.2 MB + Decoder 23.6 MB + JointDecisionv3 12.7 MB + vocabulary 0.2 MB.
    /// Whisper: the 632MB variant folder is 645.7 MB, plus a tokenizer of a few MB fetched on first load.
    var approximateDownloadBytes: Int64 {
        switch self {
        case .parakeetV3: 483_200_000
        case .whisperLargeV3Turbo: 650_000_000
        }
    }

    /// The engine's longest chunk, in seconds (Parakeet's encoder window is 15 s, Whisper's 30 s).
    var defaultMaxChunkDuration: TimeInterval {
        switch self {
        case .parakeetV3: 14.5
        case .whisperLargeV3Turbo: 28
        }
    }

    /// Whether the engine takes a vocabulary prompt (`TranscriptionContext.vocabularyPrompt`).
    var supportsVocabularyPrompt: Bool { self == .whisperLargeV3Turbo }
}
