import Foundation

/// Loads and saves `settings.json` (normally `~/Library/Application Support/devshout/settings.json`).
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// What happened when loading, for logging.
    public enum LoadNote: Sendable, Hashable {
        case loaded
        /// No file yet: defaults.
        case missing
        /// The file wasn't JSON at all. It was moved aside to `movedTo` and defaults were used.
        case unreadable(movedTo: URL?)
    }

    /// Reads the settings. Never fails: a missing file gives defaults, unknown or missing keys are tolerated, and a
    /// file that isn't JSON at all is renamed to `settings.json.unreadable-<timestamp>` and replaced by defaults.
    public func load() -> AppSettings {
        loadWithNote().settings
    }

    public func loadWithNote() -> (settings: AppSettings, note: LoadNote) {
        guard let data = try? Data(contentsOf: url) else {
            return (AppSettings.defaults, .missing)
        }
        if let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return (settings, .loaded)
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".unreadable-\(stamp)")
        let moved = (try? FileManager.default.moveItem(at: url, to: aside)) != nil
        return (AppSettings.defaults, .unreadable(movedTo: moved ? aside : nil))
    }

    /// Writes the settings atomically (temporary file, then rename), creating the folder if needed.
    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try Self.encoder.encode(settings)
        try data.write(to: url, options: .atomic)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
