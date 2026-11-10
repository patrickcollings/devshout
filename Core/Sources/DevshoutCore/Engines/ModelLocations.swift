import Foundation

/// Where devshout keeps downloaded models: `~/Library/Application Support/devshout/Models/<engine>/`.
///
/// Both engines download into these folders, never into FluidAudio's own cache or WhisperKit's default
/// `~/Documents/huggingface` (which would trigger a Documents permission prompt).
public struct ModelLocations: Sendable, Hashable {
    /// The `Models` folder.
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/devshout/Models` on macOS.
    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return base
            .appendingPathComponent("devshout", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    public static var `default`: ModelLocations { ModelLocations(root: defaultRoot) }

    /// `Models/<engine id>/`, e.g. `Models/parakeet-tdt-0.6b-v3/`. Everything an engine downloads lives in here.
    public func directory(for engine: EngineID) -> URL {
        root.appendingPathComponent(engine.rawValue, isDirectory: true)
    }

    /// `Models/silero-vad/`, for the VAD module.
    public var sileroVADDirectory: URL {
        root.appendingPathComponent("silero-vad", isDirectory: true)
    }

    // MARK: Engine-specific layout

    /// The folder FluidAudio downloads Parakeet into and loads it from:
    /// `Models/parakeet-tdt-0.6b-v3/parakeet-tdt-0.6b-v3-coreml/`. (FluidAudio treats the URL it is given as the
    /// repo folder and puts files in its parent + its own folder name, so the last component must match.)
    public var parakeetRepoDirectory: URL {
        directory(for: .parakeetV3).appendingPathComponent(EngineID.parakeetV3.modelVariant, isDirectory: true)
    }

    /// WhisperKit's `downloadBase` (and tokenizer folder): `Models/whisper-large-v3-turbo/`. WhisperKit lays its Hub
    /// cache out below it (`models/argmaxinc/whisperkit-coreml/<variant>/`).
    public var whisperDownloadBase: URL {
        directory(for: .whisperLargeV3Turbo)
    }

    /// Where the Whisper variant folder would be, following the Hub cache layout.
    public var expectedWhisperModelFolder: URL {
        whisperDownloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(EngineID.whisperLargeV3Turbo.modelVariant, isDirectory: true)
    }

    /// Written into the Whisper variant folder once a download has finished, so an interrupted download is not
    /// mistaken for a complete one.
    public static let completionMarkerName = ".devshout-complete"

    /// Compiled models that must be in the Whisper variant folder.
    public static let whisperRequiredModels = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]

    /// The finished Whisper variant folder, if there is one: the expected path first, else a search below the
    /// download base (in case WhisperKit's cache layout changes).
    public func completedWhisperModelFolder(fileManager: FileManager = .default) -> URL? {
        let candidates = [expectedWhisperModelFolder]
            + Self.findDirectories(named: EngineID.whisperLargeV3Turbo.modelVariant, under: whisperDownloadBase,
                                   maxDepth: 6, fileManager: fileManager)
        return candidates.first { Self.isCompleteWhisperFolder($0, fileManager: fileManager) }
    }

    public static func isCompleteWhisperFolder(_ folder: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: folder.appendingPathComponent(completionMarkerName).path) else { return false }
        return whisperRequiredModels.allSatisfy { name in
            var isDirectory: ObjCBool = false
            let path = folder.appendingPathComponent(name).path
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Marks a Whisper variant folder as completely downloaded.
    public static func markComplete(_ folder: URL) throws {
        try Data("ok\n".utf8).write(to: folder.appendingPathComponent(completionMarkerName), options: .atomic)
    }

    // MARK: Disk housekeeping

    /// Creates `Models/<engine>/` if needed and returns it.
    @discardableResult
    public func ensureDirectory(for engine: EngineID, fileManager: FileManager = .default) throws -> URL {
        let url = directory(for: engine)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Bytes on disk for an engine's models (0 when nothing is downloaded).
    public func sizeOnDisk(for engine: EngineID, fileManager: FileManager = .default) -> Int64 {
        Self.directorySize(directory(for: engine), fileManager: fileManager)
    }

    /// Deletes everything downloaded for an engine. Unload the engine first.
    public func deleteModels(for engine: EngineID, fileManager: FileManager = .default) throws {
        let url = directory(for: engine)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Sum of file sizes below `url` (allocated size where the file system reports it).
    public static func directorySize(_ url: URL, fileManager: FileManager = .default) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                      errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    /// Directories called `name` below `root`, at most `maxDepth` levels down, shallowest first.
    public static func findDirectories(named name: String, under root: URL, maxDepth: Int,
                                       fileManager: FileManager = .default) -> [URL] {
        var found: [URL] = []
        var level: [URL] = [root]
        for _ in 0..<maxDepth {
            var next: [URL] = []
            for dir in level {
                guard let children = try? fileManager.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { continue }
                for child in children {
                    guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                    if child.lastPathComponent == name {
                        found.append(child)
                    } else if !child.lastPathComponent.hasSuffix(".mlmodelc") {
                        next.append(child)
                    }
                }
            }
            if next.isEmpty { break }
            level = next
        }
        return found
    }
}
