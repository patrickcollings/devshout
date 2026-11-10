// The speech engines: which one is selected, downloading and preparing models with progress, switching (the old
// engine is unloaded) and deleting. Engines are actors, so all the heavy work runs off the main actor; this class
// only keeps `SpeechEngineViewModel` current.

import DevshoutCore
import DevshoutMac
import Foundation

@MainActor
final class EngineController {
    private let locations: ModelLocations
    private let model: SpeechEngineViewModel
    /// Called when the selected engine changes (to persist it and update the glossary's token counter).
    var onSelect: ((EngineID) -> Void)?
    /// Whether a dictation is using the current engine right now; unloading waits for it to finish.
    var isDictationActive: () -> Bool = { false }

    private(set) var selected: EngineID
    private var engines: [EngineID: any TranscriptionEngine] = [:]
    private var prepareTasks: [EngineID: Task<Void, Never>] = [:]
    private var pendingUnload: [EngineID] = []
    private var speedTrackers: [EngineID: SpeedTracker] = [:]
    /// The current prepare run per engine, so a cancelled run's late progress is ignored.
    private var runs: [EngineID: UUID] = [:]
    /// Engines whose model files are being removed.
    private var deleting: Set<EngineID> = []

    init(selected: EngineID, locations: ModelLocations, model: SpeechEngineViewModel) {
        self.selected = selected
        self.locations = locations
        self.model = model

        var statuses: [EngineID: SpeechModelStatus] = [:]
        for id in EngineID.allCases {
            statuses[id] = EngineFactory.isModelDownloaded(id, locations: locations)
                ? .ready(sizeOnDisk: nil) : .notDownloaded
        }
        model.sync {
            model.selectedEngine = selected
            model.statuses = statuses
        }
        model.actions = SpeechEngineViewModel.Actions(
            selectEngine: { [weak self] id in self?.select(id) },
            download: { [weak self] id in self?.download(id) },
            cancelDownload: { [weak self] id in self?.cancelDownload(id) },
            delete: { [weak self] id in self?.delete(id) }
        )
        refreshSizes()
    }

    /// The selected engine (created on first use).
    var engine: any TranscriptionEngine { instance(for: selected) }

    /// The token counter Whisper's vocabulary prompt should be measured with.
    var tokenCounter: any TokenCounter {
        (engine as? WhisperEngine)?.tokenCounter ?? ApproximateTokenCounter()
    }

    /// Why the selected model can't be used for a dictation now, if it can't: a title and a hint for the pill.
    /// Anything short of ready refuses. Loading is usually a few seconds, but the first load in this app (or after
    /// a macOS update) includes Core ML's one-off optimisation for this Mac, which takes minutes and can't be told
    /// apart from a plain load, and a dictation queued behind it would look stuck.
    var selectedModelProblem: (title: String, detail: String)? {
        if deleting.contains(selected) {
            return ("Speech model is being deleted", "Download it again in Settings → Transcription.")
        }
        let status = model.status(for: selected)
        switch status {
        case .failed(let message):
            let sentence = message.hasSuffix(".") ? message : message + "."
            return ("Speech model isn't working", "\(sentence) Try again in Settings → Transcription.")
        case .notDownloaded:
            return ("No speech model yet", "Download one in Settings → Transcription.")
        case .downloading:
            let progress = status.fraction.map { " (\(UIFormat.percent($0)))" } ?? ""
            return ("Speech model still downloading\(progress)", "It carries on in the background. Try again when it's done.")
        case .preparing:
            if model.isOptimising(selected) {
                return ("Getting the speech model ready",
                        "A one-off step on this Mac that can take several minutes. Settings shows the progress.")
            }
            return ("Speech model is loading", "Try again in a few seconds.")
        case .ready:
            return nil
        }
    }

    /// At launch: load the selected model if it's already on disk (no network needed).
    func prepareSelectedIfDownloaded() {
        guard EngineFactory.isModelDownloaded(selected, locations: locations) else { return }
        prepare(selected)
    }

    // MARK: Actions

    func select(_ id: EngineID) {
        guard id != selected else { return }
        let old = selected
        selected = id
        if model.selectedEngine != id { model.sync { model.selectedEngine = id } }
        onSelect?(id)
        unload(old)
        // Load the new one straight away if it's already downloaded; otherwise the user presses Download.
        if EngineFactory.isModelDownloaded(id, locations: locations) {
            prepare(id)
        }
    }

    func download(_ id: EngineID) {
        prepare(id)
    }

    func cancelDownload(_ id: EngineID) {
        guard let task = prepareTasks[id] else { return }
        task.cancel()
        prepareTasks[id] = nil
        runs[id] = nil
        model.preparingSince[id] = nil
        speedTrackers[id] = nil
        model.statuses[id] = EngineFactory.isModelDownloaded(id, locations: locations)
            ? .ready(sizeOnDisk: nil) : .notDownloaded
        // Whatever the library had loaded so far goes too.
        let instance = instance(for: id)
        Task { await instance.unload() }
    }

    func delete(_ id: EngineID) {
        // Not while a dictation may be using it, and not twice at once.
        guard !(id == selected && isDictationActive()), !deleting.contains(id) else { return }
        prepareTasks[id]?.cancel()
        prepareTasks[id] = nil
        runs[id] = nil
        model.preparingSince[id] = nil
        speedTrackers[id] = nil
        deleting.insert(id)
        let instance = instance(for: id)
        let locations = locations
        model.statuses[id] = .preparing(.loading)
        Task {
            await instance.unload()
            let result: Result<Void, Error> = await Task.detached {
                Result { try EngineFactory.deleteModel(id, locations: locations) }
            }.value
            self.deleting.remove(id)
            switch result {
            case .success:
                self.model.statuses[id] = .notDownloaded
            case .failure(let error):
                self.model.statuses[id] = .failed(message: "Couldn't delete the model: \(ErrorText.describe(error))")
            }
        }
    }

    /// A dictation finished: unload engines that were switched away from while it ran.
    func dictationEnded() {
        let waiting = pendingUnload
        pendingUnload = []
        for id in waiting where id != selected {
            let instance = instance(for: id)
            Task { await instance.unload() }
        }
    }

    // MARK: Private

    private func instance(for id: EngineID) -> any TranscriptionEngine {
        if let existing = engines[id] { return existing }
        let made = EngineFactory.makeEngine(id, locations: locations)
        engines[id] = made
        return made
    }

    private func unload(_ id: EngineID) {
        // A download in progress carries on (switching the selection shouldn't throw it away); prepareFinished
        // unloads the engine once it's done, because it is no longer the selected one.
        if prepareTasks[id] != nil { return }
        if isDictationActive() {
            pendingUnload.append(id)
            return
        }
        let instance = instance(for: id)
        Task { await instance.unload() }
    }

    /// Download (if needed), compile and load. Progress reaches the view model on the main actor, in order.
    /// (The controllers live as long as the app, so tasks hold them strongly.)
    private func prepare(_ id: EngineID) {
        guard prepareTasks[id] == nil, !deleting.contains(id) else { return }
        let instance = instance(for: id)
        let run = UUID()
        runs[id] = run
        model.preparingSince[id] = Date()
        let wasDownloaded = EngineFactory.isModelDownloaded(id, locations: locations)
        model.statuses[id] = wasDownloaded
            ? .preparing(.loading)
            : .downloading(fraction: 0, bytesDone: nil, bytesTotal: id.approximateDownloadBytes, bytesPerSecond: nil)
        speedTrackers[id] = SpeedTracker()
        let (updates, continuation) = AsyncStream<ModelProgress>.makeStream(bufferingPolicy: .unbounded)
        let task = Task {
            let listener = Task {
                for await progress in updates { self.apply(progress, to: id, run: run) }
            }
            var failure: Error?
            do {
                try await instance.prepare(progress: { progress in _ = continuation.yield(progress) })
            } catch {
                failure = error
            }
            continuation.finish()
            await listener.value
            guard self.runs[id] == run else { return }
            self.prepareFinished(id, error: failure)
        }
        prepareTasks[id] = task
    }

    private func apply(_ progress: ModelProgress, to id: EngineID, run: UUID) {
        // Ignore late updates from a cancelled or replaced run.
        guard runs[id] == run else { return }
        var progress = progress
        if progress.phase == .ready {
            // The size is filled in by prepareFinished.
            model.statuses[id] = .preparing(.loading)
            return
        }
        if progress.phase == .downloading {
            let total = progress.bytesTotal ?? id.approximateDownloadBytes
            progress.bytesTotal = total
            if progress.bytesDone == nil, let fraction = progress.fraction {
                progress.bytesDone = Int64(Double(total) * fraction)
            }
        }
        let speed = progress.bytesDone.flatMap { speedTrackers[id]?.update(bytes: $0) }
        model.statuses[id] = SpeechModelStatus(progress: progress, bytesPerSecond: speed)
    }

    private func prepareFinished(_ id: EngineID, error: Error?) {
        prepareTasks[id] = nil
        runs[id] = nil
        model.preparingSince[id] = nil
        speedTrackers[id] = nil
        if let error {
            if error is CancellationError { return }
            model.statuses[id] = .failed(message: ErrorText.describe(error))
            return
        }
        model.statuses[id] = .ready(sizeOnDisk: nil)
        refreshSizes()
        // A model downloaded for the engine that isn't selected doesn't need to sit in memory.
        if id != selected {
            let instance = instance(for: id)
            Task { await instance.unload() }
        }
    }

    /// Fills in "Ready · 480 MB" (walking the model folders off the main actor).
    private func refreshSizes() {
        let locations = locations
        Task {
            let sizes: [EngineID: Int64] = await Task.detached {
                var sizes: [EngineID: Int64] = [:]
                for id in EngineID.allCases where EngineFactory.isModelDownloaded(id, locations: locations) {
                    sizes[id] = EngineFactory.modelSizeOnDisk(id, locations: locations)
                }
                return sizes
            }.value
            for (id, size) in sizes where self.model.status(for: id).isReady {
                self.model.statuses[id] = .ready(sizeOnDisk: size > 0 ? size : nil)
            }
        }
    }
}

/// Download speed, smoothed, from successive byte counts (sampled at most twice a second).
private struct SpeedTracker {
    private var lastBytes: Int64?
    private var lastTime: Date?
    private var speed: Double?

    mutating func update(bytes: Int64, now: Date = Date()) -> Double? {
        guard let previousBytes = lastBytes, let previousTime = lastTime else {
            lastBytes = bytes
            lastTime = now
            return nil
        }
        let interval = now.timeIntervalSince(previousTime)
        guard interval >= 0.5 else { return speed }
        if bytes >= previousBytes {
            let instant = Double(bytes - previousBytes) / interval
            speed = speed.map { $0 * 0.7 + instant * 0.3 } ?? instant
        }
        lastBytes = bytes
        lastTime = now
        return speed
    }
}
