import Foundation

/// Timings for one bench run, in seconds. Anything not measured (Raw mode has no Claude step) is nil.
public struct BenchTimings: Codable, Sendable, Hashable {
    /// Loading the speech model (after any download).
    public var modelLoad: TimeInterval?
    /// Transcribing the whole file.
    public var transcribe: TimeInterval?
    /// Chunked mode: from the end of the audio to the final text (the tail latency the user feels).
    public var tailLatency: TimeInterval?
    /// Claude: from spawning the process to the first byte of output.
    public var claudeFirstByte: TimeInterval?
    /// Claude: from spawning the process to exit.
    public var claudeTotal: TimeInterval?

    public init(modelLoad: TimeInterval? = nil, transcribe: TimeInterval? = nil, tailLatency: TimeInterval? = nil,
                claudeFirstByte: TimeInterval? = nil, claudeTotal: TimeInterval? = nil) {
        self.modelLoad = modelLoad
        self.transcribe = transcribe
        self.tailLatency = tailLatency
        self.claudeFirstByte = claudeFirstByte
        self.claudeTotal = claudeTotal
    }
}

/// One line of a bench report: one sample, run with one engine, mode and model.
public struct BenchRow: Codable, Sendable, Hashable {
    /// "s01" … "s10" or "ramble".
    public var sample: String
    /// "parakeet", "whisper", "superwhisper", …
    public var engine: String
    /// "raw", "tidy", "structure".
    public var mode: String
    /// The Claude model ("haiku", "sonnet"), or "" / "-" when Claude was not used.
    public var model: String
    public var wer: Double?
    public var termHits: Int?
    public var termTotal: Int?
    public var pointsCovered: Int?
    public var pointsTotal: Int?
    public var timings: BenchTimings

    public init(sample: String, engine: String, mode: String, model: String = "", wer: Double? = nil,
                termHits: Int? = nil, termTotal: Int? = nil, pointsCovered: Int? = nil, pointsTotal: Int? = nil,
                timings: BenchTimings = BenchTimings()) {
        self.sample = sample
        self.engine = engine
        self.mode = mode
        self.model = model
        self.wer = wer
        self.termHits = termHits
        self.termTotal = termTotal
        self.pointsCovered = pointsCovered
        self.pointsTotal = pointsTotal
        self.timings = timings
    }

    /// A row from a scored sample.
    public init(sample: String, engine: String, mode: String, model: String = "", score: BenchScore,
                timings: BenchTimings = BenchTimings()) {
        self.init(sample: sample, engine: engine, mode: mode, model: model, wer: score.wer.wer,
                  termHits: score.terms.total == 0 ? nil : score.terms.hits,
                  termTotal: score.terms.total == 0 ? nil : score.terms.total,
                  pointsCovered: score.points?.coveredCount, pointsTotal: score.points?.total, timings: timings)
    }

    public var termHitRate: Double? {
        guard let termHits, let termTotal, termTotal > 0 else { return nil }
        return Double(termHits) / Double(termTotal)
    }

    public var pointRecall: Double? {
        guard let pointsCovered, let pointsTotal, pointsTotal > 0 else { return nil }
        return Double(pointsCovered) / Double(pointsTotal)
    }
}

/// A table of bench rows, rendered as Markdown (for `bench/results/<date>.md`) or CSV (for a spreadsheet).
public struct BenchReport: Sendable, Hashable {
    public var title: String
    /// Free text under the title, e.g. the date and machine. Optional.
    public var note: String?
    public var rows: [BenchRow]

    public init(title: String = "devshout bench", note: String? = nil, rows: [BenchRow]) {
        self.title = title
        self.note = note
        self.rows = rows
    }

    // MARK: Markdown

    static let markdownHeader = ["Sample", "Engine", "Mode", "Model", "WER", "Terms", "Points", "Load", "Transcribe",
                                 "Tail", "Claude 1st byte", "Claude total"]

    /// A title, an optional note, the full table (one row per run) and a summary per engine, mode and model.
    public func markdown() -> String {
        var out = "# \(title)\n\n"
        if let note, !note.isEmpty { out += note + "\n\n" }
        out += "## Results\n\n"
        out += table(header: Self.markdownHeader, rows: rows.map(Self.markdownCells))
        let groups = summaryGroups()
        if !groups.isEmpty {
            out += "\n## Summary\n\n"
            out += "WER is the mean over the samples; terms and points are pooled; times are means. "
            out += "A dash means not measured.\n\n"
            out += table(header: ["Engine", "Mode", "Model", "Samples", "WER", "Terms", "Points", "Load",
                                  "Transcribe", "Tail", "Claude 1st byte", "Claude total"],
                         rows: groups.map(Self.summaryCells))
        }
        return out
    }

    static func markdownCells(_ row: BenchRow) -> [String] {
        [
            row.sample, row.engine, row.mode, row.model.isEmpty ? "–" : row.model,
            percent(row.wer),
            fraction(row.termHits, row.termTotal, rate: row.termHitRate),
            fraction(row.pointsCovered, row.pointsTotal, rate: nil),
            seconds(row.timings.modelLoad), seconds(row.timings.transcribe), seconds(row.timings.tailLatency),
            seconds(row.timings.claudeFirstByte), seconds(row.timings.claudeTotal),
        ]
    }

    private func table(header: [String], rows: [[String]]) -> String {
        var out = "| " + header.joined(separator: " | ") + " |\n"
        out += "|" + header.map { _ in " --- " }.joined(separator: "|") + "|\n"
        for row in rows {
            out += "| " + row.map(Self.escapeCell).joined(separator: " | ") + " |\n"
        }
        return out
    }

    private static func escapeCell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: Summary

    struct SummaryGroup {
        var engine: String
        var mode: String
        var model: String
        var rows: [BenchRow]
    }

    /// Groups in order of first appearance.
    func summaryGroups() -> [SummaryGroup] {
        var groups: [SummaryGroup] = []
        for row in rows {
            if let i = groups.firstIndex(where: { $0.engine == row.engine && $0.mode == row.mode && $0.model == row.model }) {
                groups[i].rows.append(row)
            } else {
                groups.append(SummaryGroup(engine: row.engine, mode: row.mode, model: row.model, rows: [row]))
            }
        }
        return groups
    }

    static func summaryCells(_ group: SummaryGroup) -> [String] {
        let rows = group.rows
        let hits = rows.compactMap(\.termHits)
        let totals = rows.compactMap(\.termTotal)
        let hitSum = hits.reduce(0, +)
        let totalSum = totals.reduce(0, +)
        let covered = rows.compactMap(\.pointsCovered).reduce(0, +)
        let pointTotal = rows.compactMap(\.pointsTotal).reduce(0, +)
        return [
            group.engine, group.mode, group.model.isEmpty ? "–" : group.model, String(rows.count),
            percent(mean(rows.compactMap(\.wer))),
            totalSum == 0 ? "–" : fraction(hitSum, totalSum, rate: Double(hitSum) / Double(totalSum)),
            pointTotal == 0 ? "–" : fraction(covered, pointTotal, rate: nil),
            seconds(mean(rows.compactMap(\.timings.modelLoad))),
            seconds(mean(rows.compactMap(\.timings.transcribe))),
            seconds(mean(rows.compactMap(\.timings.tailLatency))),
            seconds(mean(rows.compactMap(\.timings.claudeFirstByte))),
            seconds(mean(rows.compactMap(\.timings.claudeTotal))),
        ]
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    // MARK: CSV

    static let csvHeader = ["sample", "engine", "mode", "model", "wer", "term_hits", "term_total", "term_hit_rate",
                            "points_covered", "points_total", "point_recall", "model_load_s", "transcribe_s",
                            "tail_latency_s", "claude_first_byte_s", "claude_total_s"]

    /// RFC 4180 CSV with a header row and `\n` line endings. Unmeasured values are empty. Ratios are 0–1.
    public func csv() -> String {
        var lines = [Self.csvHeader.joined(separator: ",")]
        for row in rows {
            let fields: [String] = [
                row.sample, row.engine, row.mode, row.model,
                Self.number(row.wer, places: 4),
                row.termHits.map(String.init) ?? "", row.termTotal.map(String.init) ?? "",
                Self.number(row.termHitRate, places: 4),
                row.pointsCovered.map(String.init) ?? "", row.pointsTotal.map(String.init) ?? "",
                Self.number(row.pointRecall, places: 4),
                Self.number(row.timings.modelLoad, places: 3), Self.number(row.timings.transcribe, places: 3),
                Self.number(row.timings.tailLatency, places: 3), Self.number(row.timings.claudeFirstByte, places: 3),
                Self.number(row.timings.claudeTotal, places: 3),
            ]
            lines.append(fields.map(Self.csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csvField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Formatting

    static func number(_ value: Double?, places: Int) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.\(places)f", value)
    }

    /// 0.1234 → "12.3%".
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return String(format: "%.1f%%", value * 100)
    }

    /// "7/9 (78%)", or "7/8" without a rate.
    static func fraction(_ numerator: Int?, _ denominator: Int?, rate: Double?) -> String {
        guard let numerator, let denominator, denominator > 0 else { return "–" }
        if let rate { return "\(numerator)/\(denominator) (\(String(format: "%.0f%%", rate * 100)))" }
        return "\(numerator)/\(denominator)"
    }

    /// 1.234 → "1.23 s".
    static func seconds(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return String(format: "%.2f s", value)
    }
}
