import Foundation
import Testing
@testable import DevshoutCore

@Suite struct ModelLocationsTests {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devshout-models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func defaultRootIsDevshoutModels() {
        let root = ModelLocations.defaultRoot
        #expect(root.lastPathComponent == "Models")
        #expect(root.deletingLastPathComponent().lastPathComponent == "devshout")
    }

    @Test func perEngineFolders() {
        let locations = ModelLocations(root: URL(fileURLWithPath: "/tmp/Models", isDirectory: true))
        #expect(locations.directory(for: .parakeetV3).path == "/tmp/Models/parakeet-tdt-0.6b-v3")
        #expect(locations.directory(for: .whisperLargeV3Turbo).path == "/tmp/Models/whisper-large-v3-turbo")
        #expect(locations.sileroVADDirectory.path == "/tmp/Models/silero-vad")
        #expect(locations.parakeetRepoDirectory.path
            == "/tmp/Models/parakeet-tdt-0.6b-v3/parakeet-tdt-0.6b-v3-coreml")
        #expect(locations.whisperDownloadBase.path == "/tmp/Models/whisper-large-v3-turbo")
        #expect(locations.expectedWhisperModelFolder.path
            == "/tmp/Models/whisper-large-v3-turbo/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo_632MB")
    }

    @Test func modelInfo() {
        #expect(EngineID.whisperLargeV3Turbo.modelVariant == "openai_whisper-large-v3-v20240930_turbo_632MB")
        #expect(EngineID.parakeetV3.modelRepository == "FluidInference/parakeet-tdt-0.6b-v3-coreml")
        #expect(EngineID.parakeetV3.defaultMaxChunkDuration == 14.5)
        #expect(EngineID.whisperLargeV3Turbo.defaultMaxChunkDuration == 28)
        #expect(EngineID.whisperLargeV3Turbo.supportsVocabularyPrompt)
        #expect(!EngineID.parakeetV3.supportsVocabularyPrompt)
        #expect(EngineID.allCases.allSatisfy { $0.approximateDownloadBytes > 100_000_000 })
    }

    @Test func sizeAndDelete() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = ModelLocations(root: root)
        #expect(locations.sizeOnDisk(for: .parakeetV3) == 0)

        let dir = try locations.ensureDirectory(for: .parakeetV3)
        let nested = dir.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: nested.appendingPathComponent("weights.bin"))
        try Data(count: 500).write(to: dir.appendingPathComponent("vocab.json"))
        #expect(locations.sizeOnDisk(for: .parakeetV3) >= 10_500)
        #expect(locations.sizeOnDisk(for: .whisperLargeV3Turbo) == 0)

        try locations.deleteModels(for: .parakeetV3)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(locations.sizeOnDisk(for: .parakeetV3) == 0)
        try locations.deleteModels(for: .parakeetV3)  // deleting nothing is fine
    }

    @Test func whisperFolderNeedsModelsAndMarker() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = ModelLocations(root: root)
        #expect(locations.completedWhisperModelFolder() == nil)

        let folder = locations.expectedWhisperModelFolder
        for name in ModelLocations.whisperRequiredModels {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        #expect(locations.completedWhisperModelFolder() == nil)  // no marker: maybe interrupted
        try ModelLocations.markComplete(folder)
        #expect(locations.completedWhisperModelFolder()?.standardizedFileURL.path == folder.standardizedFileURL.path)

        try FileManager.default.removeItem(at: folder.appendingPathComponent("TextDecoder.mlmodelc"))
        #expect(locations.completedWhisperModelFolder() == nil)
    }

    @Test func findsWhisperFolderInAnotherLayout() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = ModelLocations(root: root)
        let folder = locations.whisperDownloadBase
            .appendingPathComponent("hub/argmaxinc--whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(EngineID.whisperLargeV3Turbo.modelVariant, isDirectory: true)
        for name in ModelLocations.whisperRequiredModels {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try ModelLocations.markComplete(folder)
        #expect(locations.completedWhisperModelFolder()?.lastPathComponent == EngineID.whisperLargeV3Turbo.modelVariant)
    }
}
