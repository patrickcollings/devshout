import Foundation

/// Tuning for `ChunkPlanner` (PLAN §4.1). All durations are in seconds. Lives in settings so the spike can tune it.
///
/// Decoding is lenient: a missing key takes its default, so an older `settings.json` still loads.
public struct ChunkPlannerConfig: Codable, Sendable, Hashable {
    /// A natural cut is only made once the chunk holds at least this much speech.
    public var minSpeechBeforeCut: TimeInterval
    /// A natural cut needs a silence at least this long; the cut goes in the middle of it.
    public var cutSilence: TimeInterval
    /// A frame whose probability is at or above this starts (or continues) speech.
    public var speechThreshold: Float
    /// Hysteresis: once in speech, a frame only counts as silence when its probability is below
    /// `speechThreshold - speechExitOffset`. Frames in between keep the previous state.
    public var speechExitOffset: Float
    /// A forced cut goes at the lowest-probability frame within this long before the chunk's limit.
    public var forcedCutSearchWindow: TimeInterval
    /// After a forced cut, the next chunk starts this long before the cut, so words on the cut are heard twice.
    public var forcedCutOverlap: TimeInterval
    /// A chunk with less speech than this is not transcribed (stops Whisper hallucinating over silence).
    public var minSpeechToTranscribe: TimeInterval
    /// Audio kept either side of the speech in each chunk, so first and last phonemes aren't clipped.
    public var padding: TimeInterval

    public init(minSpeechBeforeCut: TimeInterval = 3.0,
                cutSilence: TimeInterval = 0.6,
                speechThreshold: Float = 0.3,
                speechExitOffset: Float = 0.15,
                forcedCutSearchWindow: TimeInterval = 2.0,
                forcedCutOverlap: TimeInterval = 1.0,
                minSpeechToTranscribe: TimeInterval = 0.3,
                padding: TimeInterval = 0.15) {
        self.minSpeechBeforeCut = minSpeechBeforeCut
        self.cutSilence = cutSilence
        self.speechThreshold = speechThreshold
        self.speechExitOffset = speechExitOffset
        self.forcedCutSearchWindow = forcedCutSearchWindow
        self.forcedCutOverlap = forcedCutOverlap
        self.minSpeechToTranscribe = minSpeechToTranscribe
        self.padding = padding
    }

    public static let `default` = ChunkPlannerConfig()

    /// The threshold below which a frame ends speech.
    public var speechExitThreshold: Float { speechThreshold - speechExitOffset }

    private enum CodingKeys: String, CodingKey {
        case minSpeechBeforeCut, cutSilence, speechThreshold, speechExitOffset, forcedCutSearchWindow,
             forcedCutOverlap, minSpeechToTranscribe, padding
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChunkPlannerConfig.default
        minSpeechBeforeCut = try c.decodeIfPresent(TimeInterval.self, forKey: .minSpeechBeforeCut) ?? d.minSpeechBeforeCut
        cutSilence = try c.decodeIfPresent(TimeInterval.self, forKey: .cutSilence) ?? d.cutSilence
        speechThreshold = try c.decodeIfPresent(Float.self, forKey: .speechThreshold) ?? d.speechThreshold
        speechExitOffset = try c.decodeIfPresent(Float.self, forKey: .speechExitOffset) ?? d.speechExitOffset
        forcedCutSearchWindow = try c.decodeIfPresent(TimeInterval.self, forKey: .forcedCutSearchWindow)
            ?? d.forcedCutSearchWindow
        forcedCutOverlap = try c.decodeIfPresent(TimeInterval.self, forKey: .forcedCutOverlap) ?? d.forcedCutOverlap
        minSpeechToTranscribe = try c.decodeIfPresent(TimeInterval.self, forKey: .minSpeechToTranscribe)
            ?? d.minSpeechToTranscribe
        padding = try c.decodeIfPresent(TimeInterval.self, forKey: .padding) ?? d.padding
    }
}
