// Makes the engine chosen in Settings and answers model-status questions for the Transcription tab and onboarding.
//
// Unsure of (no Mac to compile on): nothing beyond what ParakeetEngine.swift and WhisperEngine.swift list.

import DevshoutCore
import Foundation

public enum EngineFactory {
    /// A new, unloaded engine. Call `prepare(progress:)` before (or let the first `transcribe` do it).
    public static func makeEngine(_ id: EngineID, locations: ModelLocations = .default) -> any TranscriptionEngine {
        switch id {
        case .parakeetV3: return ParakeetEngine(locations: locations)
        case .whisperLargeV3Turbo: return WhisperEngine(locations: locations)
        }
    }

    /// Whether the engine's model is completely downloaded, so `prepare` needs no network.
    public static func isModelDownloaded(_ id: EngineID, locations: ModelLocations = .default) -> Bool {
        switch id {
        case .parakeetV3: return ParakeetEngine.isDownloaded(locations: locations)
        case .whisperLargeV3Turbo: return WhisperEngine.isDownloaded(locations: locations)
        }
    }

    /// Bytes the engine's models take on disk (0 when not downloaded).
    public static func modelSizeOnDisk(_ id: EngineID, locations: ModelLocations = .default) -> Int64 {
        locations.sizeOnDisk(for: id)
    }

    /// Roughly how much the first `prepare` downloads, for "Download (483 MB)".
    public static func approximateDownloadBytes(_ id: EngineID) -> Int64 {
        id.approximateDownloadBytes
    }

    /// Deletes the engine's downloaded models. Unload any engine using them first (`await engine.unload()`).
    public static func deleteModel(_ id: EngineID, locations: ModelLocations = .default) throws {
        try locations.deleteModels(for: id)
    }
}
