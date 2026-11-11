import Foundation

/// Errors from `HistoryStore`.
public enum HistoryError: Error, Sendable, Hashable {
    case notFound(UUID)
}

/// Recordings on disk: one folder per recording at `<root>/YYYY/MM/<uuid>/` holding `audio.wav` and `record.json`
/// (PLAN §3.5). `root` is normally `~/Library/Application Support/devshout/Recordings`.
///
/// Every method works straight on the file system, so the store is a plain value that any actor can use. Writes are
/// atomic (temporary file, then rename). Folders are placed by the recording's creation date in the calendar of
/// `timeZone`; lookups by id search every month folder, so a time-zone change never loses a recording.
public struct HistoryStore: Sendable {
    public static let audioFileName = "audio.wav"
    public static let recordFileName = "record.json"

    public let root: URL
    public let dateSource: any DateSource
    public let timeZone: TimeZone

    public init(root: URL, dateSource: any DateSource = SystemDateSource(), timeZone: TimeZone = .current) {
        self.root = root
        self.dateSource = dateSource
        self.timeZone = timeZone
    }

    private var fileManager: FileManager { .default }

    // MARK: Creating

    /// Makes the folder for a new recording, dated now. The recorder writes to `audioURL`; nothing exists there yet.
    public func newRecordingFolder() throws -> (id: UUID, audioURL: URL) {
        let id = UUID()
        let folder = folderURL(for: id, createdAt: dateSource.now())
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return (id, folder.appendingPathComponent(Self.audioFileName))
    }

    /// Writes `record.json` into the recording's folder (found by id, else made from `createdAt`).
    public func save(_ recording: Recording) throws {
        let folder = existingFolder(for: recording.id) ?? folderURL(for: recording.id, createdAt: recording.createdAt)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(recording)
        try data.write(to: folder.appendingPathComponent(Self.recordFileName), options: .atomic)
    }

    /// Adds a clean version (a re-run from History) and saves.
    @discardableResult
    public func appendVersion(_ version: CleanVersion, to id: UUID) throws -> Recording {
        guard var recording = try load(id) else { throw HistoryError.notFound(id) }
        recording.versions.append(version)
        try save(recording)
        return recording
    }

    // MARK: Reading

    /// Every recording with a readable `record.json`, newest first. Damaged records are skipped.
    public func list() -> [Recording] {
        recordingFolders().compactMap { readRecord(in: $0) }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString > $1.id.uuidString }
    }

    /// The recording, or `nil` when there is none with that id. Throws when `record.json` exists but can't be read.
    public func load(_ id: UUID) throws -> Recording? {
        guard let folder = existingFolder(for: id) else { return nil }
        let url = folder.appendingPathComponent(Self.recordFileName)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Self.decoder.decode(Recording.self, from: Data(contentsOf: url))
    }

    /// The recording's folder, when it exists.
    public func folder(for id: UUID) -> URL? { existingFolder(for: id) }

    /// `audio.wav`, when it still exists.
    public func audioURL(for id: UUID) -> URL? {
        guard let folder = existingFolder(for: id) else { return nil }
        let url = folder.appendingPathComponent(Self.audioFileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Deleting

    /// Deletes the recording's folder (audio and text). Deleting one that doesn't exist does nothing.
    public func delete(_ id: UUID) throws {
        guard let folder = existingFolder(for: id) else { return }
        try fileManager.removeItem(at: folder)
        pruneEmptyParents(of: folder)
    }

    /// Deletes every recording ("Delete all history…").
    public func deleteAll() throws {
        guard fileManager.fileExists(atPath: root.path) else { return }
        for item in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try fileManager.removeItem(at: item)
        }
    }

    /// Deletes `audio.wav` from recordings older than `audioDays` days, keeping their text. `nil` or ≤ 0 keeps audio
    /// for ever. Folders without `record.json` are left alone (`recoverOrphans` deals with them).
    /// Returns the ids whose audio was deleted.
    @discardableResult
    public func applyRetention(now: Date, audioDays: Int?) -> [UUID] {
        guard let audioDays, audioDays > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(audioDays) * 86_400)
        var deleted: [UUID] = []
        for folder in recordingFolders() {
            guard var recording = readRecord(in: folder), recording.createdAt < cutoff else { continue }
            let audio = folder.appendingPathComponent(Self.audioFileName)
            guard fileManager.fileExists(atPath: audio.path) else { continue }
            do {
                try fileManager.removeItem(at: audio)
                recording.audioDeletedAt = now
                try save(recording)
                deleted.append(recording.id)
            } catch {
                continue
            }
        }
        return deleted
    }

    // MARK: Recovery

    /// On launch: every folder with `audio.wav` but no `record.json` (the app quit or crashed mid-dictation) gets a
    /// record with status `recovered`, dated from the file and timed from the audio on disk: the WAV header is
    /// repaired first, because the recorder only patches its sizes every 2 s, so after a crash it undercounts the
    /// end of the recording (and anything reading the file later would drop that tail). Empty folders are removed. Pass the ids of recordings in progress in `excluding` (normally none at launch).
    /// Returns the recovered recordings.
    @discardableResult
    public func recoverOrphans(excluding: Set<UUID> = []) -> [Recording] {
        var recovered: [Recording] = []
        for folder in recordingFolders() {
            guard let id = UUID(uuidString: folder.lastPathComponent), !excluding.contains(id) else { continue }
            let record = folder.appendingPathComponent(Self.recordFileName)
            guard !fileManager.fileExists(atPath: record.path) else { continue }
            let audio = folder.appendingPathComponent(Self.audioFileName)
            guard fileManager.fileExists(atPath: audio.path) else {
                if (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                    try? fileManager.removeItem(at: folder)
                    pruneEmptyParents(of: folder)
                }
                continue
            }
            let attributes = try? fileManager.attributesOfItem(atPath: audio.path)
            let createdAt = (attributes?[.creationDate] as? Date)
                ?? (attributes?[.modificationDate] as? Date)
                ?? dateSource.now()
            // Not one of the recorder's own files (or not writable): leave it alone and take what the header says.
            let duration = (try? WavFileWriter.repairHeader(at: audio)) ?? WAVInfo.read(audio)?.duration ?? 0
            let recording = Recording(
                id: id,
                createdAt: createdAt,
                duration: duration,
                status: .recovered,
                errorMessage: "devshout quit before this recording finished. The audio was kept."
            )
            if (try? save(recording)) != nil { recovered.append(recording) }
        }
        return recovered
    }

    // MARK: Layout

    func folderURL(for id: UUID, createdAt: Date) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month], from: createdAt)
        let year = String(format: "%04d", parts.year ?? 1970)
        let month = String(format: "%02d", parts.month ?? 1)
        return root.appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func existingFolder(for id: UUID) -> URL? {
        recordingFolders().first { $0.lastPathComponent.caseInsensitiveCompare(id.uuidString) == .orderedSame }
    }

    /// Every `<root>/YYYY/MM/<uuid>` folder.
    private func recordingFolders() -> [URL] {
        func subfolders(_ url: URL) -> [URL] {
            let items = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles])) ?? []
            return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        return subfolders(root).flatMap(subfolders).flatMap(subfolders)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
    }

    private func readRecord(in folder: URL) -> Recording? {
        let url = folder.appendingPathComponent(Self.recordFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(Recording.self, from: data)
    }

    /// Removes the month and year folders above a deleted recording when they are empty.
    private func pruneEmptyParents(of folder: URL) {
        var parent = folder.deletingLastPathComponent()
        for _ in 0..<2 {
            guard parent.standardizedFileURL.path != root.standardizedFileURL.path,
                  (try? fileManager.contentsOfDirectory(atPath: parent.path))?.isEmpty == true
            else { return }
            try? fileManager.removeItem(at: parent)
            parent = parent.deletingLastPathComponent()
        }
    }

    // MARK: Coding

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(HistoryDates.format(date))
        }
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let seconds = try? c.decode(Double.self) { return Date(timeIntervalSince1970: seconds) }
            let string = try c.decode(String.self)
            guard let date = HistoryDates.parse(string) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO 8601 date: \(string)")
            }
            return date
        }
        return decoder
    }
}

/// ISO 8601 with milliseconds, in UTC (`2026-11-10T14:02:03.250Z`).
enum HistoryDates {
    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
