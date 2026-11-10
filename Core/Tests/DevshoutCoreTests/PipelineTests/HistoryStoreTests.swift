import Foundation
import Testing
@testable import DevshoutCore

@Suite struct HistoryStoreTests {
    static let utc = TimeZone(identifier: "UTC")!
    // 2026-11-10T12:00:00Z
    static let now = Date(timeIntervalSince1970: 1_794_312_000)

    func makeStore(_ temp: TempDir, at date: Date = HistoryStoreTests.now) -> (HistoryStore, FixedDateSource) {
        let dates = FixedDateSource(date)
        return (HistoryStore(root: temp.url, dateSource: dates, timeZone: Self.utc), dates)
    }

    func recording(_ id: UUID, daysAgo: Double, text: String = "hello") -> Recording {
        Recording(id: id, createdAt: Self.now.addingTimeInterval(-daysAgo * 86_400), duration: 2, mode: .tidy,
                  targetApp: TargetApp(bundleID: "com.apple.Notes", name: "Notes"), engine: .parakeetV3,
                  rawText: text, deliveredText: text, delivered: DeliveryRecord(.copiedOnly(reason: "No text field")))
    }

    @Test func folderLayout() throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let (store, _) = makeStore(temp)
        let (id, audioURL) = try store.newRecordingFolder()
        #expect(audioURL.lastPathComponent == "audio.wav")
        let folder = audioURL.deletingLastPathComponent()
        #expect(folder.lastPathComponent == id.uuidString)
        #expect(folder.deletingLastPathComponent().lastPathComponent == "11")
        #expect(folder.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "2026")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(store.folder(for: id)?.standardizedFileURL == folder.standardizedFileURL)
    }

    @Test func saveLoadAndList() throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let (store, _) = makeStore(temp)
        let old = recording(UUID(), daysAgo: 40, text: "old")
        var new = recording(UUID(), daysAgo: 0, text: "new")
        new.versions = [CleanVersion(mode: .tidy, model: "haiku", text: "New.", elapsed: 1.25, warnings: ["w"],
                                     createdAt: Self.now)]
        new.timings = RecordingTimings(transcription: 0.5, cleaning: 1.25, delivery: 0.05, total: 1.8)
        try store.save(old)
        try store.save(new)

        #expect(try store.load(new.id) == new)
        #expect(try store.load(UUID()) == nil)
        #expect(store.list().map(\.id) == [new.id, old.id])
        #expect(store.list().first?.bestText == "New.")
        #expect(store.list().last?.bestText == "old")

        // The old one lives under its own month.
        #expect(store.folder(for: old.id)?.deletingLastPathComponent().lastPathComponent == "10")

        // Saving again overwrites in place.
        var updated = new
        updated.status = .failed
        try store.save(updated)
        #expect(try store.load(new.id)?.status == .failed)
        #expect(store.list().count == 2)
    }

    @Test func savesIntoTheFolderMadeForTheRecording() throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let (store, dates) = makeStore(temp)
        let (id, audioURL) = try store.newRecordingFolder()
        try TestWAV.data(sampleCount: 16).write(to: audioURL)
        // Even if the record's date falls in another month, it is written next to its audio.
        dates.advance(40 * 86_400)
        try store.save(Recording(id: id, createdAt: dates.now()))
        #expect(store.audioURL(for: id)?.resolvingSymlinksInPath() == audioURL.resolvingSymlinksInPath())
        #expect(FileManager.default.fileExists(atPath: audioURL.deletingLastPathComponent()
            .appendingPathComponent("record.json").path))
    }

    @Test func appendVersion() throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let (store, _) = makeStore(temp)
        let r = recording(UUID(), daysAgo: 1)
        try store.save(r)
        let version = CleanVersion(mode: .structure, model: "sonnet", text: "- Hello", elapsed: 2, createdAt: Self.now)
        try store.appendVersion(version, to: r.id)
        #expect(try store.load(r.id)?.versions == [version])
        #expect(try store.load(r.id)?.latestVersion == version)
        #expect(throws: HistoryError.self) { try store.appendVersion(version, to: UUID()) }
    }

    @Test func deleteRemovesTheFolderAndEmptyParents() throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let (store, _) = makeStore(temp)
        let a = recording(UUID(), daysAgo: 0)
        let b = recording(UUID(), daysAgo: 0)
        let c = recording(UUID(), daysAgo: 400)
        for r in [a, b, c] { try store.save(r) }

        try store.delete(a.id)
        #expect(try store.load(a.id) == nil)
        let remaining = Set(store.list().map(\.id))
        #expect(remaining == [b.id, c.id])
        #expect(FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("2026/11").path))

        try store.delete(c.id)
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("2025").path))
        try store.delete(UUID())  // no-op

        try store.deleteAll()
        #expect(store.list().isEmpty)
        #expect(FileManager.default.fileExists(atPath: temp.url.path))
    }

    @Test func retentionDeletesOldAudioButKeepsText() throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let (store, _) = makeStore(temp)
        let old = recording(UUID(), daysAgo: 31, text: "old")
        let recent = recording(UUID(), daysAgo: 29, text: "recent")
        let oldWithoutAudio = recording(UUID(), daysAgo: 60)
        for r in [old, recent, oldWithoutAudio] { try store.save(r) }
        for r in [old, recent] {
            let folder = try #require(store.folder(for: r.id))
            try TestWAV.data(sampleCount: 160).write(to: folder.appendingPathComponent("audio.wav"))
        }

        #expect(store.applyRetention(now: Self.now, audioDays: nil).isEmpty)
        #expect(store.applyRetention(now: Self.now, audioDays: 0).isEmpty)
        #expect(store.audioURL(for: old.id) != nil)

        #expect(store.applyRetention(now: Self.now, audioDays: 30) == [old.id])
        #expect(store.audioURL(for: old.id) == nil)
        #expect(store.audioURL(for: recent.id) != nil)
        let kept = try #require(try store.load(old.id))
        #expect(kept.rawText == "old")
        #expect(kept.audioDeletedAt == Self.now)
        #expect(try store.load(oldWithoutAudio.id)?.audioDeletedAt == nil)

        // Running again finds nothing more.
        #expect(store.applyRetention(now: Self.now, audioDays: 30).isEmpty)
    }

    @Test func recoverOrphans() throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let (store, _) = makeStore(temp)

        // Crashed mid-recording: audio (header never patched) but no record.
        let (orphan, orphanAudio) = try store.newRecordingFolder()
        try TestWAV.data(sampleCount: 48_000, patchSizes: false).write(to: orphanAudio)
        // In progress right now: left alone.
        let (live, liveAudio) = try store.newRecordingFolder()
        try TestWAV.data(sampleCount: 16_000).write(to: liveAudio)
        // Finished normally.
        let (done, doneAudio) = try store.newRecordingFolder()
        try TestWAV.data(sampleCount: 16_000).write(to: doneAudio)
        try store.save(recording(done, daysAgo: 0))
        // Never got audio.
        let (empty, _) = try store.newRecordingFolder()
        // Not a recording folder at all.
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("2026/11/not-a-uuid"),
                                                withIntermediateDirectories: true)

        let recovered = store.recoverOrphans(excluding: [live])
        #expect(recovered.map(\.id) == [orphan])
        let saved = try #require(try store.load(orphan))
        #expect(saved.status == .recovered)
        #expect(saved.duration == 3)
        #expect(saved.errorMessage != nil)
        #expect(store.audioURL(for: orphan)?.resolvingSymlinksInPath() == orphanAudio.resolvingSymlinksInPath())
        #expect(try store.load(live) == nil)
        #expect(try store.load(done)?.status == .completed)
        #expect(store.folder(for: empty) == nil)

        #expect(store.recoverOrphans(excluding: [live]).isEmpty)
        #expect(Set(store.list().map(\.id)) == [orphan, done])
    }

    @Test func tolerantRecordDecoding() throws {
        let r = try HistoryStore.decoder.decode(Recording.self, from: pipelineFixture("record-tolerant"))
        #expect(r.id == UUID(uuidString: "5A3C1F0E-2B7D-4C1A-9E8F-0123456789AB"))
        #expect(r.status == .failed)  // unknown status
        #expect(r.mode == .structure)
        #expect(r.targetApp?.name == "Terminal")
        #expect(r.transcript == "check the CORSIA flag")
        #expect(r.versions.count == 1)  // the version without text is dropped
        #expect(r.versions.first?.createdAt == Date(timeIntervalSince1970: 1_794_319_329.25))
        #expect(r.delivered?.outcome == .pasted(appName: "Terminal"))
        #expect(r.timings.delivery == nil)
        #expect(r.timings.total == 3.7)
        #expect(r.deliveredText == nil)
    }

    @Test func damagedRecordsAreSkippedByList() throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let (store, _) = makeStore(temp)
        let good = recording(UUID(), daysAgo: 0)
        try store.save(good)
        let (bad, _) = try store.newRecordingFolder()
        try Data("{ not json".utf8).write(to: try #require(store.folder(for: bad)).appendingPathComponent("record.json"))
        #expect(store.list().map(\.id) == [good.id])
        #expect(throws: (any Error).self) { try store.load(bad) }
    }

    @Test func datesKeepMilliseconds() throws {
        let date = Date(timeIntervalSince1970: 1_794_312_000.25)
        let data = try HistoryStore.encoder.encode(Recording(id: UUID(), createdAt: date))
        #expect(String(decoding: data, as: UTF8.self).contains("2026-11-10T12:00:00.250Z"))
        #expect(try HistoryStore.decoder.decode(Recording.self, from: data).createdAt == date)
    }
}

@Suite struct WAVInfoTests {
    @Test func patchedHeader() {
        let info = WAVInfo.parse(header: TestWAV.data(sampleCount: 32_000), fileSize: 44 + 64_000)
        #expect(info == WAVInfo(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: 64_000))
        #expect(info?.duration == 2)
    }

    @Test func unpatchedHeaderUsesTheFileSize() {
        let data = TestWAV.data(sampleCount: 8_000, patchSizes: false)
        #expect(WAVInfo.parse(header: data.prefix(44), fileSize: data.count)?.duration == 0.5)
    }

    @Test func notAWAV() {
        #expect(WAVInfo.parse(header: Data("hello world, not a wav".utf8), fileSize: 22) == nil)
        #expect(WAVInfo.parse(header: Data(), fileSize: 0) == nil)
    }

    @Test func readsFromDisk() throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let url = temp.url.appendingPathComponent("a.wav")
        try TestWAV.data(sampleCount: 4_000).write(to: url)
        #expect(WAVInfo.read(url)?.duration == 0.25)
        #expect(WAVInfo.read(temp.url.appendingPathComponent("missing.wav")) == nil)
    }
}
