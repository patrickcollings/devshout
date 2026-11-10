import Foundation

/// A sentence and the recording of it being read.
public struct CalibrationRecording: Sendable, Hashable {
    public var sentence: CalibrationSentence
    public var audioURL: URL

    public init(sentence: CalibrationSentence, audioURL: URL) {
        self.sentence = sentence
        self.audioURL = audioURL
    }
}

/// What an engine made of one recording.
public struct CalibrationTranscript: Sendable, Hashable {
    public var text: String
    public var audioSeconds: TimeInterval
    /// The engine's own time (not loading the model, not the voice activity detector).
    public var processingSeconds: TimeInterval

    public init(text: String, audioSeconds: TimeInterval, processingSeconds: TimeInterval) {
        self.text = text
        self.audioSeconds = audioSeconds
        self.processingSeconds = processingSeconds
    }
}

/// Where the analysis has got to.
public enum CalibrationProgress: Sendable, Hashable {
    /// Loading an engine's model (the first load in an app can take minutes).
    case loading(EngineID)
    /// `done` of `total` recordings transcribed with this engine.
    case transcribing(EngineID, done: Int, total: Int)

    /// Overall progress, 0…1, for `engineIndex` of `engineCount` engines.
    public func fraction(engineIndex: Int, engineCount: Int) -> Double {
        guard engineCount > 0 else { return 0 }
        let within: Double
        switch self {
        case .loading: within = 0
        case .transcribing(_, let done, let total): within = total > 0 ? Double(done) / Double(total) : 0
        }
        return (Double(engineIndex) + within) / Double(engineCount)
    }
}

/// Everything the analysis produced.
public struct CalibrationAnalysis: Sendable, Hashable {
    public var scores: [CalibrationEngineScore]
    public var failures: [CalibrationEngineFailure]
    /// Every transcript, for `CalibrationLearning`.
    public var observations: [CalibrationLearning.Observation]

    public init(scores: [CalibrationEngineScore] = [], failures: [CalibrationEngineFailure] = [],
                observations: [CalibrationLearning.Observation] = []) {
        self.scores = scores
        self.failures = failures
        self.observations = observations
    }

    public var recommendation: CalibrationRecommendation { CalibrationRecommendation.decide(scores) }
}

/// Runs every recording through each engine, one engine at a time (they share the Neural Engine), and scores the
/// transcripts. The engines themselves are behind closures, so the app, `devshout-cli calibrate` and the tests run
/// exactly the same analysis.
public struct CalibrationAnalyser: Sendable {
    /// Load the engine's model. A throw means the engine is reported as failed and the others still run.
    public var prepare: @Sendable (EngineID) async throws -> Void
    /// Transcribe one recording the way the app would (`CalibrationTranscriber`).
    public var transcribe: @Sendable (CalibrationRecording, EngineID) async throws -> CalibrationTranscript
    /// The engine is finished with (unload it if nothing else needs it). Always called after `prepare`.
    public var release: @Sendable (EngineID) async -> Void
    /// A readable sentence for an engine's error.
    public var describe: @Sendable (any Error) -> String

    public init(prepare: @escaping @Sendable (EngineID) async throws -> Void,
                transcribe: @escaping @Sendable (CalibrationRecording, EngineID) async throws -> CalibrationTranscript,
                release: @escaping @Sendable (EngineID) async -> Void = { _ in },
                describe: @escaping @Sendable (any Error) -> String = { $0.localizedDescription }) {
        self.prepare = prepare
        self.transcribe = transcribe
        self.release = release
        self.describe = describe
    }

    /// Throws only `CancellationError`, when the task is cancelled (the engine in use is still released).
    public func run(recordings: [CalibrationRecording], engines: [EngineID], glossary: Glossary,
                    progress: @escaping @Sendable (CalibrationProgress, _ engineIndex: Int) -> Void = { _, _ in }) async throws -> CalibrationAnalysis {
        let terms = CalibrationScorer.glossaryTerms(glossary)
        var analysis = CalibrationAnalysis()
        for (engineIndex, engine) in engines.enumerated() {
            try Task.checkCancellation()
            progress(.loading(engine), engineIndex)
            do {
                try await prepare(engine)
            } catch {
                await release(engine)
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                analysis.failures.append(CalibrationEngineFailure(engine: engine, message: describe(error)))
                continue
            }

            var scores: [CalibrationSentenceScore] = []
            var observations: [CalibrationLearning.Observation] = []
            var failure: String?
            for (index, recording) in recordings.enumerated() {
                if Task.isCancelled {
                    await release(engine)
                    throw CancellationError()
                }
                progress(.transcribing(engine, done: index, total: recordings.count), engineIndex)
                do {
                    let transcript = try await transcribe(recording, engine)
                    scores.append(CalibrationScorer.score(sentence: recording.sentence, transcript: transcript.text,
                                                          audioSeconds: transcript.audioSeconds,
                                                          processingSeconds: transcript.processingSeconds,
                                                          glossaryTerms: terms))
                    observations.append(.init(engine: engine, sentence: recording.sentence, transcript: transcript.text))
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        await release(engine)
                        throw CancellationError()
                    }
                    // An engine that can't get through the script isn't compared on part of it.
                    failure = describe(error)
                    break
                }
            }
            await release(engine)
            if let failure {
                analysis.failures.append(CalibrationEngineFailure(engine: engine, message: failure))
            } else {
                progress(.transcribing(engine, done: recordings.count, total: recordings.count), engineIndex)
                analysis.scores.append(CalibrationEngineScore(engine: engine, sentences: scores))
                analysis.observations += observations
            }
        }
        return analysis
    }
}

/// One recording through the app's own pipeline: voice activity detection, the chunk planner, the engine, the
/// stitcher and the glossary's fixes (`SpikeTranscriber`, which the bench uses too), with Whisper given its
/// vocabulary prompt. So the text that is scored is the text a Raw dictation would have pasted.
public enum CalibrationTranscriber {
    /// - Parameter vad: nil when the detector isn't available; the recording then goes to the engine in one piece
    ///   (a sentence is far shorter than either engine's limit).
    public static func transcribe(samples: [Float], engine: any TranscriptionEngine,
                                  vad: (any VoiceActivityDetector)?,
                                  vadRemainder: (@Sendable () async throws -> Float?)? = nil,
                                  tokenCounter: any TokenCounter = ApproximateTokenCounter(),
                                  glossary: Glossary) async throws -> CalibrationTranscript {
        let transcriber = SpikeTranscriber(engine: engine, vad: vad, vadRemainder: vadRemainder, tokenCounter: tokenCounter)
        let options = SpikeTranscriptionOptions(mode: vad == nil ? .single : .whole, glossary: glossary)
        let result = try await transcriber.run(samples: samples, options: options)
        return CalibrationTranscript(text: result.text, audioSeconds: result.audioDuration,
                                     processingSeconds: result.timings.transcribe)
    }
}
