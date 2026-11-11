import Foundation

/// How a recording ended.
public enum RecordingStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case completed
    /// Esc while recording. The audio is kept.
    case cancelled
    /// Something failed after recording started. Audio and whatever text existed are kept.
    case failed
    /// Found on launch with audio but no `record.json` (the app quit or crashed mid-dictation).
    case recovered

    public var displayName: String {
        switch self {
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        case .recovered: "Recovered recording"
        }
    }
}

/// The app that had focus when recording started.
public struct TargetApp: Codable, Sendable, Hashable {
    public var bundleID: String?
    public var name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// One clean-up result. A dictation has at most one; each re-run from History adds another.
public struct CleanVersion: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var mode: ModeID
    /// The name of `mode` when this was made, kept for custom modes only so the version can still be labelled
    /// after the mode is deleted. Nil for the built-ins.
    public var modeName: String?
    public var model: String
    public var text: String
    public var elapsed: TimeInterval
    public var warnings: [String]
    public var createdAt: Date

    public init(id: UUID = UUID(), mode: ModeID, modeName: String? = nil, model: String, text: String,
                elapsed: TimeInterval, warnings: [String] = [], createdAt: Date) {
        self.id = id
        self.mode = mode
        self.modeName = modeName
        self.model = model
        self.text = text
        self.elapsed = elapsed
        self.warnings = warnings
        self.createdAt = createdAt
    }

    public init(_ result: CleanResult, mode: ModeID, modeName: String? = nil, createdAt: Date) {
        self.init(mode: mode, modeName: modeName, model: result.model, text: result.text, elapsed: result.elapsed,
                  warnings: result.warnings, createdAt: createdAt)
    }

    enum CodingKeys: String, CodingKey { case id, mode, modeName, model, text, elapsed, warnings, createdAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(UUID.self, .id) ?? UUID()
        mode = c.lenient(ModeID.self, .mode) ?? .tidy
        modeName = c.lenient(String.self, .modeName)
        model = c.lenient(String.self, .model) ?? ""
        text = try c.decode(String.self, forKey: .text)
        elapsed = c.lenient(TimeInterval.self, .elapsed) ?? 0
        warnings = c.lenient([String].self, .warnings) ?? []
        createdAt = c.lenient(Date.self, .createdAt) ?? Date(timeIntervalSince1970: 0)
    }
}

/// `DeliveryOutcome` as stored in `record.json`.
public struct DeliveryRecord: Codable, Sendable, Hashable {
    public enum Method: String, Codable, Sendable, Hashable { case pasted, copiedOnly, failed }
    public var method: Method
    /// The app the text was pasted into (pasted only).
    public var appName: String?
    /// Why no paste was sent (copied only).
    public var reason: String?

    public init(_ outcome: DeliveryOutcome) {
        switch outcome {
        case .pasted(let appName):
            method = .pasted
            self.appName = appName
            reason = nil
        case .copiedOnly(let reason):
            method = .copiedOnly
            appName = nil
            self.reason = reason
        case .failed(let reason):
            method = .failed
            appName = nil
            self.reason = reason
        }
    }

    public var outcome: DeliveryOutcome {
        switch method {
        case .pasted: .pasted(appName: appName)
        case .copiedOnly: .copiedOnly(reason: reason ?? "")
        case .failed: .failed(reason: reason ?? "")
        }
    }
}

/// Seconds spent in each stage. `nil` means the stage didn't run.
public struct RecordingTimings: Codable, Sendable, Hashable {
    /// From pressing stop to the stitched transcript (chunk planning + every chunk).
    public var transcription: TimeInterval?
    public var cleaning: TimeInterval?
    public var delivery: TimeInterval?
    /// From pressing stop to delivery: the latency the user feels.
    public var total: TimeInterval?

    public init(transcription: TimeInterval? = nil, cleaning: TimeInterval? = nil,
                delivery: TimeInterval? = nil, total: TimeInterval? = nil) {
        self.transcription = transcription
        self.cleaning = cleaning
        self.delivery = delivery
        self.total = total
    }
}

/// Everything known about one dictation: `record.json` in its folder.
public struct Recording: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    /// Seconds of audio.
    public var duration: TimeInterval
    public var status: RecordingStatus
    /// The mode the dictation finished in (after any switch while recording).
    public var mode: ModeID
    /// The name of `mode` at the time, kept for custom modes only (`AppSettings.storedName(for:)`): History shows
    /// it once the mode has been deleted. Nil for the built-ins and in records from before custom modes.
    public var modeName: String?
    public var targetApp: TargetApp?
    public var engine: EngineID?
    /// The stitched engine output, before glossary fixes.
    public var rawText: String?
    /// The text after glossary fixes, when they ran.
    public var fixedText: String?
    /// Whether the glossary fixes ran (they can be switched off).
    public var fixesApplied: Bool
    public var versions: [CleanVersion]
    /// The text that was delivered (the clean version, or the raw text when clean-up was skipped or failed).
    public var deliveredText: String?
    public var delivered: DeliveryRecord?
    /// Set when Tidy/Structure fell back to the raw text: why.
    public var fallbackReason: String?
    public var timings: RecordingTimings
    public var errorMessage: String?
    /// When retention removed `audio.wav`.
    public var audioDeletedAt: Date?

    public init(id: UUID, createdAt: Date, duration: TimeInterval = 0, status: RecordingStatus = .completed,
                mode: ModeID = .tidy, modeName: String? = nil, targetApp: TargetApp? = nil,
                engine: EngineID? = nil,
                rawText: String? = nil, fixedText: String? = nil, fixesApplied: Bool = false,
                versions: [CleanVersion] = [], deliveredText: String? = nil, delivered: DeliveryRecord? = nil,
                fallbackReason: String? = nil, timings: RecordingTimings = RecordingTimings(),
                errorMessage: String? = nil, audioDeletedAt: Date? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.status = status
        self.mode = mode
        self.modeName = modeName
        self.targetApp = targetApp
        self.engine = engine
        self.rawText = rawText
        self.fixedText = fixedText
        self.fixesApplied = fixesApplied
        self.versions = versions
        self.deliveredText = deliveredText
        self.delivered = delivered
        self.fallbackReason = fallbackReason
        self.timings = timings
        self.errorMessage = errorMessage
        self.audioDeletedAt = audioDeletedAt
    }

    /// The transcript to show as "Raw": fixed text when fixes ran, else the engine output.
    public var transcript: String? { fixedText ?? rawText }

    /// The newest clean version.
    public var latestVersion: CleanVersion? { versions.max(by: { $0.createdAt < $1.createdAt }) }

    /// The best text to copy: the latest clean version, else the transcript.
    public var bestText: String? { latestVersion?.text ?? transcript }

    // MARK: Codable (tolerant: history must always list, even with old or damaged records)

    enum CodingKeys: String, CodingKey {
        case id, createdAt, duration, status, mode, modeName, targetApp, engine, rawText, fixedText, fixesApplied, versions,
             deliveredText, delivered, fallbackReason, timings, errorMessage, audioDeletedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = c.lenient(Date.self, .createdAt) ?? Date(timeIntervalSince1970: 0)
        duration = c.lenient(TimeInterval.self, .duration) ?? 0
        status = c.lenient(RecordingStatus.self, .status) ?? .failed
        mode = c.lenient(ModeID.self, .mode) ?? .tidy
        modeName = c.lenient(String.self, .modeName)
        targetApp = c.lenient(TargetApp.self, .targetApp)
        engine = c.lenient(EngineID.self, .engine)
        rawText = c.lenient(String.self, .rawText)
        fixedText = c.lenient(String.self, .fixedText)
        fixesApplied = c.lenient(Bool.self, .fixesApplied) ?? false
        versions = (c.lenient([LenientValue<CleanVersion>].self, .versions) ?? []).compactMap(\.value)
        deliveredText = c.lenient(String.self, .deliveredText)
        delivered = c.lenient(DeliveryRecord.self, .delivered)
        fallbackReason = c.lenient(String.self, .fallbackReason)
        timings = c.lenient(RecordingTimings.self, .timings) ?? RecordingTimings()
        errorMessage = c.lenient(String.self, .errorMessage)
        audioDeletedAt = c.lenient(Date.self, .audioDeletedAt)
    }
}
