// The view model for "Calibrate your voice": the window's stage, the script, the take being recorded, the analysis
// progress and the results with their tick boxes. Like the others, it only holds state and forwards button presses
// to `Actions`, which `CalibrationController` fills in.

import Combine
import DevshoutCore
import Foundation
import SwiftUI

/// Which screen the calibration window shows.
enum CalibrationStage: Hashable, Sendable {
    /// What this is and what will happen.
    case intro
    /// Claude is writing sentences around the glossary terms (a few seconds; can be skipped).
    case preparing
    /// Reading the script, a sentence at a time.
    case reading
    /// The engines are transcribing the recordings.
    case analysing
    case results
    /// Nothing could be measured.
    case failed(message: String)
}

/// The microphone, for the sentence on screen.
enum CalibrationRecordingState: Hashable, Sendable {
    case idle
    /// The microphone is opening.
    case starting
    case recording(since: Date)
    /// The file is being closed.
    case stopping
}

/// Where the analysis has got to.
struct CalibrationProgressState: Hashable, Sendable {
    /// 0…1 over every engine.
    var fraction: Double = 0
    var engine: EngineID? = nil
    /// The engine's model is loading (as opposed to transcribing).
    var isLoading = false
    var done = 0
    var total = 0
}

/// What the results screen shows.
struct CalibrationResults: Hashable, Sendable {
    var scores: [CalibrationEngineScore]
    var failures: [CalibrationEngineFailure]
    var recommendation: CalibrationRecommendation
    /// Engines that weren't ready, so weren't measured.
    var notCompared: [EngineID]

    var summary: String { recommendation.summary(scores: scores, notCompared: notCompared) }
}

/// A learned mishearing with its tick box.
struct CalibrationCorrectionRow: Identifiable, Hashable, Sendable {
    var correction: LearnedCorrection
    var isSelected: Bool
    /// Already added to the glossary.
    var isApplied = false

    var id: String { correction.id }
}

/// A note about an ordinary word with its tick box.
struct CalibrationNoteRow: Identifiable, Hashable, Sendable {
    var note: LearnedStyleNote
    var isSelected = false
    var isApplied = false

    var id: String { note.id }
}

/// The last finished calibration, for Settings → Transcription.
struct CalibrationLastResult: Hashable, Sendable {
    var date: Date
    /// "Whisper 96%, Parakeet 89%"
    var accuracySummary: String
}

@MainActor
final class CalibrationViewModel: ObservableObject {
    struct Actions {
        /// Show the calibration window (Settings → Transcription, onboarding's last step).
        var open: @MainActor () -> Void = {}
        /// Leave the introduction: write the script and show the first sentence.
        var begin: @MainActor () -> Void = {}
        /// Stop waiting for Claude and use the built-in sentences.
        var useBuiltInSentences: @MainActor () -> Void = {}
        /// Record the sentence on screen (replacing any earlier take of it).
        var startRecording: @MainActor () -> Void = {}
        var stopRecording: @MainActor () -> Void = {}
        /// Every sentence is recorded: run the engines.
        var analyse: @MainActor () -> Void = {}
        var cancelAnalysis: @MainActor () -> Void = {}
        /// Make this the engine dictation uses.
        var switchEngine: @MainActor (EngineID) -> Void = { _ in }
        /// Add the ticked mishearings and notes to the glossary.
        var applyLearning: @MainActor ([LearnedCorrection], [LearnedStyleNote]) -> Void = { _, _ in }
        /// Close the window (Done, Close).
        var close: @MainActor () -> Void = {}
    }

    @Published var stage: CalibrationStage = .intro
    @Published var sentences: [CalibrationSentence] = []
    /// The sentence on screen.
    @Published var index = 0
    /// How long each recorded sentence's take is, by sentence id.
    @Published var takes: [String: TimeInterval] = [:]
    @Published var recording: CalibrationRecordingState = .idle
    /// A line under the sentence: why recording didn't start, or that a take was too short.
    @Published var notice: String? = nil
    @Published var progress = CalibrationProgressState()
    @Published var results: CalibrationResults? = nil
    @Published var corrections: [CalibrationCorrectionRow] = []
    @Published var notes: [CalibrationNoteRow] = []
    /// Shown after "Add to Glossary": what was added, or why it couldn't be.
    @Published var learningMessage: String? = nil
    @Published var learningFailed = false
    @Published var lastResult: CalibrationLastResult? = nil

    /// The input level while a take is being recorded (its own model: nothing else feeds or reads it).
    let level: AudioLevelViewModel
    let speech: SpeechEngineViewModel
    let microphone: MicrophoneViewModel
    var actions: Actions

    private var cancellables: Set<AnyCancellable> = []

    init(speech: SpeechEngineViewModel? = nil, microphone: MicrophoneViewModel? = nil,
         level: AudioLevelViewModel? = nil, actions: Actions = Actions()) {
        let speech = speech ?? SpeechEngineViewModel()
        let microphone = microphone ?? MicrophoneViewModel()
        self.speech = speech
        self.microphone = microphone
        self.level = level ?? AudioLevelViewModel()
        self.actions = actions

        // The introduction and the results depend on which models are ready and which engine is selected.
        Publishers.MergeMany([speech.objectWillChange, microphone.objectWillChange])
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: Introduction

    /// Engines whose models are ready to be measured.
    var readyEngines: [EngineID] { EngineID.allCases.filter { speech.status(for: $0).isReady } }
    var missingEngines: [EngineID] { EngineID.allCases.filter { !speech.status(for: $0).isReady } }
    var microphoneDenied: Bool { microphone.permission == .denied }
    var canBegin: Bool { !readyEngines.isEmpty && !microphoneDenied }

    func open() { actions.open() }
    func begin() { if canBegin { actions.begin() } }
    func useBuiltInSentences() { actions.useBuiltInSentences() }

    // MARK: Reading

    var currentSentence: CalibrationSentence? { sentences.indices.contains(index) ? sentences[index] : nil }
    var isLastSentence: Bool { index >= sentences.count - 1 }
    var hasTake: Bool { currentSentence.map { takes[$0.id] != nil } ?? false }
    var currentTakeDuration: TimeInterval? { currentSentence.flatMap { takes[$0.id] } }
    var isIdle: Bool { recording == .idle }
    var isRecording: Bool { if case .recording = recording { true } else { false } }
    var recordingSince: Date? { if case .recording(let since) = recording { since } else { nil } }
    var canGoBack: Bool { index > 0 && isIdle }
    var recordedCount: Int { sentences.filter { takes[$0.id] != nil }.count }

    func record() {
        guard isIdle else { return }
        actions.startRecording()
    }

    func stop() {
        guard isRecording else { return }
        actions.stopRecording()
    }

    /// On to the next sentence, or to the analysis after the last one.
    func next() {
        guard isIdle, hasTake else { return }
        notice = nil
        if isLastSentence {
            actions.analyse()
        } else {
            index += 1
        }
    }

    func back() {
        guard canGoBack else { return }
        notice = nil
        index -= 1
    }

    func cancelAnalysis() { actions.cancelAnalysis() }

    // MARK: Results

    /// The engine the results suggest switching to, when it isn't the one in use.
    var engineToSwitchTo: EngineID? {
        guard let engine = results?.recommendation.engine, engine != speech.selectedEngine,
              results?.recommendation.verdict != .onlyOne else { return nil }
        return engine
    }

    func switchEngine() {
        if let engine = engineToSwitchTo { actions.switchEngine(engine) }
    }

    var hasLearningToOffer: Bool { !corrections.isEmpty || !notes.isEmpty }

    var selectedLearningCount: Int {
        corrections.filter { $0.isSelected && !$0.isApplied }.count + notes.filter { $0.isSelected && !$0.isApplied }.count
    }

    func applyLearning() {
        let chosen = corrections.filter { $0.isSelected && !$0.isApplied }.map(\.correction)
        let chosenNotes = notes.filter { $0.isSelected && !$0.isApplied }.map(\.note)
        guard !chosen.isEmpty || !chosenNotes.isEmpty else { return }
        actions.applyLearning(chosen, chosenNotes)
    }

    func correctionBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { self.corrections.first { $0.id == id }?.isSelected ?? false },
                set: { value in
                    if let i = self.corrections.firstIndex(where: { $0.id == id }) { self.corrections[i].isSelected = value }
                })
    }

    func noteBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { self.notes.first { $0.id == id }?.isSelected ?? false },
                set: { value in
                    if let i = self.notes.firstIndex(where: { $0.id == id }) { self.notes[i].isSelected = value }
                })
    }

    func close() { actions.close() }

    /// Wiring: back to the introduction, ready for the next time the window opens. The last result stays.
    func reset() {
        stage = .intro
        sentences = []
        index = 0
        takes = [:]
        recording = .idle
        notice = nil
        progress = CalibrationProgressState()
        results = nil
        corrections = []
        notes = []
        learningMessage = nil
        learningFailed = false
        level.reset()
    }
}

// MARK: - Preview data

extension PreviewData {
    static let calibrationScript: [CalibrationSentence] = CalibrationScriptBuilder.script(glossary: GlossaryParser.parse(glossaryText))

    static let calibrationScores: [CalibrationEngineScore] = [
        CalibrationEngineScore(engine: .parakeetV3, sentences: [
            CalibrationSentenceScore(sentenceID: "c01", transcript: "", audioSeconds: 60, processingSeconds: 2.1,
                                     referenceWords: 150, wordErrors: 16, termCount: 10, termHits: 6),
        ]),
        CalibrationEngineScore(engine: .whisperLargeV3Turbo, sentences: [
            CalibrationSentenceScore(sentenceID: "c01", transcript: "", audioSeconds: 60, processingSeconds: 8.4,
                                     referenceWords: 150, wordErrors: 6, termCount: 10, termHits: 9),
        ]),
    ]

    /// A calibration window model in a given stage.
    static func calibration(_ stage: CalibrationStage, speechStatus: SpeechModelStatus = .ready(sizeOnDisk: 486_000_000),
                            recording: CalibrationRecordingState = .idle, recorded: Int = 2,
                            bothEngines: Bool = true) -> CalibrationViewModel {
        let speech = speech(speechStatus)
        if bothEngines { speech.statuses[.whisperLargeV3Turbo] = .ready(sizeOnDisk: 650_000_000) }
        let model = CalibrationViewModel(speech: speech, microphone: microphone(),
                                         level: AudioLevelViewModel(history: levelHistory))
        model.stage = stage
        model.sentences = calibrationScript
        model.index = recorded
        for sentence in calibrationScript.prefix(recorded) { model.takes[sentence.id] = 6.2 }
        model.recording = recording
        model.progress = CalibrationProgressState(fraction: 0.35, engine: .parakeetV3, isLoading: false, done: 7, total: 10)
        if stage == .results {
            let scores = bothEngines ? calibrationScores : Array(calibrationScores.prefix(1))
            model.results = CalibrationResults(scores: scores, failures: [],
                                               recommendation: CalibrationRecommendation.decide(scores),
                                               notCompared: bothEngines ? [] : [.whisperLargeV3Turbo])
            model.corrections = [
                CalibrationCorrectionRow(correction: LearnedCorrection(term: "CORSIA", heard: "causia", engines: [.parakeetV3, .whisperLargeV3Turbo],
                                                                       count: 2, isOrdinaryPhrase: false), isSelected: true),
                CalibrationCorrectionRow(correction: LearnedCorrection(term: "proponent", heard: "component", engines: [.parakeetV3],
                                                                       count: 1, isOrdinaryPhrase: true), isSelected: false),
            ]
            model.notes = [CalibrationNoteRow(note: LearnedStyleNote(said: "work", written: "walk",
                                                                     engines: [.parakeetV3, .whisperLargeV3Turbo], count: 2))]
        }
        model.lastResult = CalibrationLastResult(date: Date().addingTimeInterval(-3 * 86_400), accuracySummary: "Whisper 96%, Parakeet 89%")
        return model
    }
}
