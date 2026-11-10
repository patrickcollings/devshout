import Foundation

/// An engine that couldn't be measured, and why.
public struct CalibrationEngineFailure: Codable, Sendable, Hashable {
    public var engine: EngineID
    public var message: String

    public init(engine: EngineID, message: String) {
        self.engine = engine
        self.message = message
    }
}

/// One finished calibration, as saved in `result.json`: what was read, how each engine did, what was recommended
/// and what the user did about it. Settings shows the latest one.
///
/// The format is meant to grow (a later version may add what was learned about the speaker's pace, for tuning
/// the chunk planner): every field but the date decodes with a default when missing, and unknown fields are
/// ignored.
public struct CalibrationRecord: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    /// A `heard:` form that was added to the glossary.
    public struct AppliedCorrection: Codable, Sendable, Hashable {
        public var term: String
        public var heard: String

        public init(term: String, heard: String) {
            self.term = term
            self.heard = heard
        }
    }

    /// What the user accepted from the results screen.
    public struct Applied: Codable, Sendable, Hashable {
        public var corrections: [AppliedCorrection]
        /// Lines added to the glossary's Style section.
        public var styleNotes: [String]
        /// The engine the user switched to from the results screen, if they did.
        public var switchedTo: EngineID?

        public init(corrections: [AppliedCorrection] = [], styleNotes: [String] = [], switchedTo: EngineID? = nil) {
            self.corrections = corrections
            self.styleNotes = styleNotes
            self.switchedTo = switchedTo
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            corrections = (try? c.decodeIfPresent([AppliedCorrection].self, forKey: .corrections)) ?? []
            styleNotes = (try? c.decodeIfPresent([String].self, forKey: .styleNotes)) ?? []
            switchedTo = try? c.decodeIfPresent(EngineID.self, forKey: .switchedTo)
        }
    }

    public var version: Int
    public var date: Date
    public var sentences: [CalibrationSentence]
    public var engines: [CalibrationEngineScore]
    public var failures: [CalibrationEngineFailure]
    /// The engine that was selected when the calibration ran.
    public var selectedEngine: EngineID?
    public var recommendation: CalibrationRecommendation
    public var applied: Applied

    public init(version: Int = currentVersion, date: Date, sentences: [CalibrationSentence],
                engines: [CalibrationEngineScore], failures: [CalibrationEngineFailure] = [],
                selectedEngine: EngineID? = nil, recommendation: CalibrationRecommendation? = nil,
                applied: Applied = Applied()) {
        self.version = version
        self.date = date
        self.sentences = sentences
        self.engines = engines
        self.failures = failures
        self.selectedEngine = selectedEngine
        self.recommendation = recommendation ?? CalibrationRecommendation.decide(engines)
        self.applied = applied
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        date = try c.decode(Date.self, forKey: .date)
        sentences = (try? c.decodeIfPresent([CalibrationSentence].self, forKey: .sentences)) ?? []
        engines = (try? c.decodeIfPresent([CalibrationEngineScore].self, forKey: .engines)) ?? []
        failures = (try? c.decodeIfPresent([CalibrationEngineFailure].self, forKey: .failures)) ?? []
        selectedEngine = try? c.decodeIfPresent(EngineID.self, forKey: .selectedEngine)
        recommendation = (try? c.decodeIfPresent(CalibrationRecommendation.self, forKey: .recommendation))
            ?? CalibrationRecommendation.decide(engines)
        applied = (try? c.decodeIfPresent(Applied.self, forKey: .applied)) ?? Applied()
    }

    /// "Whisper 96%, Parakeet 89%": the engines' word accuracy, best first.
    public var accuracySummary: String {
        engines.sorted { $0.wordAccuracy > $1.wordAccuracy }
            .map { "\($0.engine.shortName) \(CalibrationRecommendation.percent($0.wordAccuracy))" }
            .joined(separator: ", ")
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The Calibration folder: one sub-folder per session, named for when it started, holding that session's
/// recordings (`c01.wav` …) and, once it has been analysed, `result.json`.
///
/// ```
/// Calibration/2026-11-10-143012/c01.wav … c10.wav  result.json
/// ```
public struct CalibrationStore: Sendable, Hashable {
    public static let resultFileName = "result.json"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The folder for a session starting at `date` (not created).
    public func sessionDirectory(startingAt date: Date, timeZone: TimeZone = .current) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return root.appendingPathComponent(formatter.string(from: date), isDirectory: true)
    }

    /// Where a sentence's recording goes.
    public static func audioURL(for sentenceID: String, in session: URL) -> URL {
        session.appendingPathComponent("\(sentenceID).wav", isDirectory: false)
    }

    /// Writes `result.json` in the session's folder, atomically.
    public func save(_ record: CalibrationRecord, in session: URL) throws {
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let data = try CalibrationRecord.encoder().encode(record)
        try data.write(to: session.appendingPathComponent(Self.resultFileName), options: [.atomic])
    }

    private func sessions() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The most recent saved result, by its date. Results that can't be read are skipped.
    public func latest() -> CalibrationRecord? {
        let decoder = CalibrationRecord.decoder()
        return sessions()
            .compactMap { session -> CalibrationRecord? in
                guard let data = try? Data(contentsOf: session.appendingPathComponent(Self.resultFileName)) else { return nil }
                return try? decoder.decode(CalibrationRecord.self, from: data)
            }
            .max { $0.date < $1.date }
    }

    /// Tidies up after a session: every other session keeps only its `result.json` (its recordings are deleted), and
    /// sessions that never produced a result are removed altogether. The session passed in is left alone, so its
    /// recordings are there to analyse again.
    public func prune(keeping current: URL?) {
        let fileManager = FileManager.default
        for session in sessions() where session.standardizedFileURL != current?.standardizedFileURL {
            let result = session.appendingPathComponent(Self.resultFileName)
            guard fileManager.fileExists(atPath: result.path) else {
                try? fileManager.removeItem(at: session)
                continue
            }
            let files = (try? fileManager.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension.lowercased() == "wav" {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
