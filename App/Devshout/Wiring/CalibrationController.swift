// "Calibrate your voice": the window, the script (with Claude's help when it is connected), recording each sentence
// to its own WAV, running every ready engine over the recordings, and applying what was learned to the glossary.
//
// The measuring, the recommendation and the learning are Core's (CalibrationAnalyser and friends, shared with
// `devshout-cli calibrate`); this class owns the microphone and the engines for the length of a calibration and
// keeps `CalibrationViewModel` current. The analysis runs off the main actor: the engines and the voice activity
// detector are actors, and `CalibrationAnalyser.run` is a plain async function.
//
// Calibration and dictation never record at the same time: a take is refused while a dictation is in progress, and
// `dictationBlocker` makes DictationController refuse a hotkey while a take is being recorded or the engines are
// measuring (they share the microphone and the Neural Engine).

import AppKit
import DevshoutCore
import DevshoutMac
import Foundation

@MainActor
final class CalibrationController {
    struct Services {
        var paths: AppPaths
        var settings: () -> AppSettings
        var engines: EngineController
        var glossary: GlossaryController
        /// Settings → Glossary's editor, which must show what calibration adds.
        var glossaryEditor: GlossaryViewModel
        var claude: ClaudeController
        var vad: SileroVAD
        var levelMeter: LevelMeterController
        var isDictationActive: () -> Bool
    }

    /// A take shorter than this can't be a whole sentence.
    static let minimumTake: TimeInterval = 1
    /// A take is stopped after this long, in case the window was left recording.
    static let maximumTake: TimeInterval = 60

    private let services: Services
    private let model: CalibrationViewModel
    private let window: CalibrationWindowController
    private let store: CalibrationStore

    /// The folder of the calibration in progress (its recordings and, once analysed, result.json).
    private var session: URL?
    /// The glossary as it was when the script was written: the analysis scores against the same one.
    private var glossary: Glossary = .empty
    private var scriptRun = UUID()
    private var scriptTask: Task<Void, Never>?

    private var recorder: MicRecorder?
    private var recordingSentenceID: String?
    /// Changes whenever the current take is finished or abandoned, so a late callback is ignored.
    private var recordRun = UUID()
    private var startTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?

    private var analysisTask: Task<Void, Never>?
    private var isAnalysing = false
    private var observations: [CalibrationLearning.Observation] = []
    private var record: CalibrationRecord?

    init(services: Services, model: CalibrationViewModel) {
        self.services = services
        self.model = model
        store = CalibrationStore(root: services.paths.calibration)
        window = CalibrationWindowController(model: model)
        window.onClose = { [weak self] in self?.windowClosed() }

        model.actions = CalibrationViewModel.Actions(
            open: { [weak self] in self?.open() },
            begin: { [weak self] in self?.begin() },
            useBuiltInSentences: { [weak self] in self?.useBuiltInSentences() },
            startRecording: { [weak self] in self?.startRecording() },
            stopRecording: { [weak self] in self?.stopRecording(tooLong: false) },
            analyse: { [weak self] in self?.analyse() },
            cancelAnalysis: { [weak self] in self?.cancelAnalysis() },
            switchEngine: { [weak self] engine in self?.switchEngine(to: engine) },
            applyLearning: { [weak self] corrections, notes in self?.applyLearning(corrections, notes) },
            close: { [weak self] in self?.window.close() }
        )
    }

    // MARK: State other controllers ask about

    /// A take is being recorded (or the microphone is opening or closing for one).
    var isRecording: Bool { recorder != nil }
    /// The engines are loaded and transcribing for calibration.
    var isUsingEngines: Bool { isAnalysing }

    /// Why a dictation can't start right now, as a title and a detail for the pill; nil when it can.
    var dictationBlocker: (title: String, detail: String)? {
        // A cancelled analysis may take a while to let go of an engine (a model that is still loading can't be
        // interrupted); it no longer stops a dictation, which only has to share the Neural Engine with it.
        let isMeasuring = isAnalysing && analysisTask.map { !$0.isCancelled } == true
        guard isRecording || isMeasuring else { return nil }
        return (CalibrationCopy.dictationBlockedTitle, CalibrationCopy.dictationBlockedDetail)
    }

    // MARK: Opening and closing

    /// At launch: the last result, for Settings → Transcription.
    func loadLastResult() {
        let store = store
        Task {
            let latest = await Task.detached(priority: .utility) { store.latest() }.value
            if let latest, self.model.lastResult == nil { self.model.lastResult = Self.lastResult(latest) }
        }
    }

    func open() {
        window.show()
    }

    /// Everything the calibration holds is let go here, whatever SwiftUI reports: the microphone, the engines (by
    /// cancelling the analysis) and the request to Claude. A calibration that wasn't analysed leaves nothing behind.
    private func windowClosed() {
        scriptRun = UUID()
        scriptTask?.cancel()
        scriptTask = nil
        abandonRecording()
        analysisTask?.cancel()
        analysisTask = nil
        if let session, record == nil {
            let started = startTask
            Task.detached(priority: .utility) {
                // Let the recorder close its file first.
                await started?.value
                try? FileManager.default.removeItem(at: session)
            }
        }
        session = nil
        record = nil
        observations = []
        model.reset()
    }

    // MARK: The script

    private func begin() {
        guard model.canBegin else { return }
        // "Try Again" after a failure: drop what the failed run left.
        if let session, record == nil { try? FileManager.default.removeItem(at: session) }
        record = nil
        observations = []
        model.reset()

        glossary = (try? services.glossary.file.load()) ?? .empty
        session = store.sessionDirectory(startingAt: Date())
        let glossary = glossary

        // Claude writes the glossary sentences when it is connected and there are terms to write about.
        let groups = CalibrationScriptBuilder.termGroups(for: glossary)
        guard services.claude.canCleanNow, !groups.isEmpty else {
            show(CalibrationScriptBuilder.script(glossary: glossary))
            return
        }
        model.stage = .preparing
        let run = UUID()
        scriptRun = run
        let writer = services.claude.sentenceWriter
        scriptTask = Task {
            let sentences = await CalibrationScriptBuilder.script(glossary: glossary, writer: { try await writer.write($0) })
            guard self.scriptRun == run else { return }
            self.show(sentences)
        }
    }

    /// Don't wait for Claude any longer.
    private func useBuiltInSentences() {
        guard model.stage == .preparing else { return }
        scriptRun = UUID()
        scriptTask?.cancel()
        scriptTask = nil
        show(CalibrationScriptBuilder.script(glossary: glossary))
    }

    private func show(_ sentences: [CalibrationSentence]) {
        scriptTask = nil
        model.sentences = sentences
        model.index = 0
        model.takes = [:]
        model.notice = nil
        model.stage = .reading
    }

    // MARK: Recording

    private func startRecording() {
        guard model.stage == .reading, recorder == nil, let sentence = model.currentSentence, let session else { return }
        if services.isDictationActive() {
            model.notice = CalibrationCopy.dictationInProgress
            return
        }
        if MicrophonePermission.status == .denied || MicrophonePermission.status == .restricted {
            model.notice = CalibrationCopy.microphoneDenied
            return
        }
        model.notice = nil
        model.takes[sentence.id] = nil
        model.recording = .starting
        // The Settings and onboarding meters step aside, as they do for a dictation.
        services.levelMeter.setPaused(true)

        let level = model.level
        let recorder = MicRecorder(deviceUID: services.settings().inputDeviceUID, levelHandler: { measured in
            let value = measured.meterValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { level.push(value) }
            }
        })
        self.recorder = recorder
        recordingSentenceID = sentence.id
        let run = UUID()
        recordRun = run
        let url = CalibrationStore.audioURL(for: sentence.id, in: session)
        let previous = startTask
        startTask = Task {
            // An abandoned take may still be closing its file.
            await previous?.value
            try? FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            do {
                // The audio goes to disk first; nothing else needs the samples yet, so the stream is only drained.
                let stream = try await recorder.start(writingTo: url)
                Task.detached { for await _ in stream {} }
                guard self.recordRun == run else {
                    // The window closed while the microphone was opening.
                    await recorder.cancel()
                    return
                }
                self.model.recording = .recording(since: Date())
                self.autoStopTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(Self.maximumTake * 1_000_000_000))
                    guard !Task.isCancelled, self.recordRun == run else { return }
                    self.stopRecording(tooLong: true)
                }
            } catch {
                guard self.recordRun == run else { return }
                self.recordingEnded()
                self.model.notice = CalibrationCopy.couldNotRecord(ErrorText.describe(error))
            }
        }
    }

    private func stopRecording(tooLong: Bool) {
        guard case .recording = model.recording, let recorder, let sentenceID = recordingSentenceID, let session else { return }
        let run = recordRun
        autoStopTask?.cancel()
        autoStopTask = nil
        model.recording = .stopping
        Task {
            let duration = (try? await recorder.stop()) ?? 0
            let writeError = recorder.writeError
            guard self.recordRun == run else { return }
            self.recordingEnded()
            let url = CalibrationStore.audioURL(for: sentenceID, in: session)
            if let writeError {
                try? FileManager.default.removeItem(at: url)
                self.model.notice = CalibrationCopy.couldNotRecord(ErrorText.describe(writeError))
            } else if duration < Self.minimumTake {
                try? FileManager.default.removeItem(at: url)
                self.model.notice = CalibrationCopy.takeTooShort
            } else {
                self.model.takes[sentenceID] = duration
                self.model.notice = tooLong ? CalibrationCopy.takeTooLong : nil
            }
        }
    }

    /// The take is over (stopped, failed or abandoned): back to idle, and the other meters may run again.
    private func recordingEnded() {
        recordRun = UUID()
        autoStopTask?.cancel()
        autoStopTask = nil
        recorder = nil
        recordingSentenceID = nil
        model.recording = .idle
        model.level.reset()
        services.levelMeter.setPaused(false)
    }

    /// The window is closing mid-take: stop the microphone now. Safe to call when nothing is recording.
    private func abandonRecording() {
        guard let recorder else { return }
        let started = startTask
        recordingEnded()
        startTask = Task {
            // If start() hasn't returned yet it sees the new `recordRun` and cancels the recorder itself; this
            // covers the take that was already running.
            await started?.value
            await recorder.cancel()
        }
    }

    // MARK: Analysis

    private func analyse() {
        guard model.stage == .reading, recorder == nil, let session else { return }
        if isAnalysing {
            // A cancelled analysis is still finishing its current sentence.
            model.notice = CalibrationCopy.stillStopping
            return
        }
        if services.isDictationActive() {
            model.notice = CalibrationCopy.dictationInProgress
            return
        }
        let recordings = model.sentences.compactMap { sentence -> CalibrationRecording? in
            guard model.takes[sentence.id] != nil else { return nil }
            return CalibrationRecording(sentence: sentence, audioURL: CalibrationStore.audioURL(for: sentence.id, in: session))
        }
        guard !recordings.isEmpty else {
            model.stage = .failed(message: CalibrationCopy.nothingRecorded)
            return
        }
        let engineIDs = services.engines.calibrationCandidates
        guard !engineIDs.isEmpty else {
            model.stage = .failed(message: CalibrationCopy.noEngineReady)
            return
        }

        isAnalysing = true
        model.progress = CalibrationProgressState(engine: engineIDs.first, isLoading: true, total: recordings.count)
        model.stage = .analysing

        var instances: [EngineID: any TranscriptionEngine] = [:]
        for id in engineIDs { instances[id] = services.engines.engineForCalibration(id) }
        let engines = instances
        let controller = services.engines
        let vad = services.vad
        let glossary = glossary
        let analyser = CalibrationAnalyser(
            prepare: { id in
                guard let engine = engines[id] else { return }
                try await engine.prepare(progress: { _ in })
                // Dictation copes without the detector; so does this, but try once to have it.
                if await !vad.isReady { try? await vad.prepare() }
            },
            transcribe: { recording, id in
                guard let engine = engines[id] else { throw CancellationError() }
                let samples = try WavFileReader.read16kMono(recording.audioURL)
                let hasVAD = await vad.isReady
                let counter: any TokenCounter = (engine as? WhisperEngine)?.tokenCounter ?? ApproximateTokenCounter()
                return try await CalibrationTranscriber.transcribe(
                    samples: samples, engine: engine, vad: hasVAD ? vad : nil,
                    vadRemainder: { try await vad.processRemainder() }, tokenCounter: counter, glossary: glossary)
            },
            release: { id in await controller.calibrationFinished(with: id) },
            describe: { ErrorText.describe($0) })

        let engineCount = engineIDs.count
        analysisTask = Task {
            let result: CalibrationAnalysis?
            do {
                result = try await analyser.run(recordings: recordings, engines: engineIDs, glossary: glossary,
                                                progress: { step, index in
                    Task { @MainActor in self.show(step, engineIndex: index, engineCount: engineCount) }
                })
            } catch {
                result = nil
            }
            self.isAnalysing = false
            self.analysisTask = nil
            // Cancelled (the Cancel button, or the window closed, which has already reset everything).
            guard let result, !Task.isCancelled, self.session == session else { return }
            self.finish(result, sentences: recordings.map(\.sentence), session: session)
        }
    }

    private func show(_ step: CalibrationProgress, engineIndex: Int, engineCount: Int) {
        guard isAnalysing, model.stage == .analysing else { return }
        let fraction = step.fraction(engineIndex: engineIndex, engineCount: engineCount)
        // Updates hop to the main actor one by one and may arrive out of order: never go backwards.
        guard fraction >= model.progress.fraction else { return }
        switch step {
        case .loading(let engine):
            model.progress = CalibrationProgressState(fraction: fraction, engine: engine, isLoading: true,
                                                      done: 0, total: model.progress.total)
        case .transcribing(let engine, let done, let total):
            model.progress = CalibrationProgressState(fraction: fraction, engine: engine, isLoading: false,
                                                      done: done, total: total)
        }
    }

    /// Back to the last sentence, with every take kept.
    private func cancelAnalysis() {
        guard model.stage == .analysing else { return }
        analysisTask?.cancel()
        model.stage = .reading
        model.progress = CalibrationProgressState()
    }

    private func finish(_ analysis: CalibrationAnalysis, sentences: [CalibrationSentence], session: URL) {
        guard !analysis.scores.isEmpty else {
            let reasons = analysis.failures.map(CalibrationCopy.failure).joined(separator: "\n")
            model.stage = .failed(message: reasons.isEmpty ? CalibrationCopy.noEngineReady : reasons)
            return
        }
        observations = analysis.observations

        // Which of the words the engines wrote are ordinary English (the spelling checker is main-thread only).
        let ordinary = OrdinaryWords.ordinary(among: CalibrationLearning.transcriptWords(analysis.observations))
        let corrections = CalibrationLearning.corrections(observations: analysis.observations, glossary: glossary,
                                                          isOrdinaryWord: { ordinary.contains($0) })
        let notes = CalibrationLearning.styleNotes(observations: analysis.observations, glossary: glossary)

        let record = CalibrationRecord(date: Date(), sentences: sentences, engines: analysis.scores,
                                       failures: analysis.failures, selectedEngine: services.engines.selected)
        self.record = record
        save(record, in: session, pruning: true)

        let measured = Set(analysis.scores.map(\.engine)).union(analysis.failures.map(\.engine))
        model.results = CalibrationResults(scores: analysis.scores, failures: analysis.failures,
                                           recommendation: record.recommendation,
                                           notCompared: EngineID.allCases.filter { !measured.contains($0) })
        model.corrections = corrections.map { CalibrationCorrectionRow(correction: $0, isSelected: $0.isSuggested) }
        model.notes = notes.map { CalibrationNoteRow(note: $0) }
        model.learningMessage = nil
        model.learningFailed = false
        model.lastResult = Self.lastResult(record)
        model.stage = .results
    }

    /// Writes result.json. With `pruning`, older sessions then keep only their result (their recordings go) and
    /// abandoned ones are removed; this session keeps its recordings until the next calibration.
    private func save(_ record: CalibrationRecord, in session: URL, pruning: Bool = false) {
        let store = store
        Task.detached(priority: .utility) {
            do {
                try store.save(record, in: session)
            } catch {
                NSLog("devshout: couldn't save the calibration result: \(ErrorText.describe(error))")
            }
            if pruning { store.prune(keeping: session) }
        }
    }

    private static func lastResult(_ record: CalibrationRecord) -> CalibrationLastResult {
        CalibrationLastResult(date: record.date, accuracySummary: record.accuracySummary)
    }

    // MARK: Acting on the results

    private func switchEngine(to engine: EngineID) {
        services.engines.select(engine)
        guard var record, let session else { return }
        record.applied.switchedTo = engine
        self.record = record
        save(record, in: session)
    }

    /// Adds the ticked mishearings as `heard:` forms on their terms, and the ticked notes to the Style section, in
    /// glossary.md, and reloads the glossary for the pipeline and the editor.
    private func applyLearning(_ corrections: [LearnedCorrection], _ notes: [LearnedStyleNote]) {
        let noteTexts = notes.map(\.text)
        let people = Set(glossary.people.map { $0.term.lowercased() })
        do {
            // Mishearings go through the same path as History's "Add correction…" (the file, the pipeline and the
            // editor are all brought up to date by it).
            for correction in corrections {
                let kind: GlossaryEditor.CorrectionKind = people.contains(correction.term.lowercased()) ? .person : .term
                try services.glossary.addCorrection(heard: correction.heard, term: correction.term, kind: kind)
            }
            if !noteTexts.isEmpty {
                let file = services.glossary.file
                let onDisk = try file.loadText()
                let updated = GlossaryEditor.addingStyleNotes(noteTexts, to: onDisk)
                if updated != onDisk {
                    try file.save(text: updated)
                    services.glossary.state.update(GlossaryParser.parse(updated))
                    services.glossaryEditor.savedElsewhere(updated) { draft in
                        GlossaryEditor.addingStyleNotes(noteTexts, to: draft)
                    }
                }
            }
        } catch {
            model.learningMessage = CalibrationCopy.couldNotApply(ErrorText.describe(error))
            model.learningFailed = true
            return
        }

        let appliedCorrections = Set(corrections.map(\.id)), appliedNotes = Set(notes.map(\.id))
        for index in model.corrections.indices where appliedCorrections.contains(model.corrections[index].id) {
            model.corrections[index].isApplied = true
        }
        for index in model.notes.indices where appliedNotes.contains(model.notes[index].id) {
            model.notes[index].isApplied = true
        }
        model.learningMessage = CalibrationCopy.applied(corrections: corrections.count, notes: notes.count)
        model.learningFailed = false

        guard var record, let session else { return }
        record.applied.corrections += corrections.map { .init(term: $0.term, heard: $0.heard) }
        record.applied.styleNotes += noteTexts
        self.record = record
        save(record, in: session)
    }
}
