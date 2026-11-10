import Foundation

/// The calibration's results as plain text, for `devshout-cli calibrate`: the same numbers, recommendation and
/// learned corrections as the app's results screen.
public enum CalibrationReport {
    /// "93%"
    public static func accuracy(_ score: CalibrationEngineScore) -> String {
        CalibrationRecommendation.percent(score.wordAccuracy)
    }

    /// "8 of 10 (80%)", or "none in the script".
    public static func terms(_ score: CalibrationEngineScore) -> String {
        guard let rate = score.termHitRate else { return "none in the script" }
        return "\(score.termHits) of \(score.termCount) (\(CalibrationRecommendation.percent(rate)))"
    }

    /// "2.1 s per minute of audio"
    public static func speed(_ score: CalibrationEngineScore) -> String {
        guard let seconds = score.secondsPerMinute else { return "not measured" }
        return String(format: "%.1f s per minute of audio", seconds)
    }

    /// "Parakeet", "Parakeet and Whisper".
    public static func engineList(_ engines: [EngineID]) -> String {
        let names = engines.map(\.shortName)
        if names.count <= 1 { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    public static func text(sentences: [CalibrationSentence], analysis: CalibrationAnalysis,
                            corrections: [LearnedCorrection], styleNotes: [LearnedStyleNote],
                            notCompared: [EngineID] = [], details: Bool = false) -> String {
        var lines: [String] = []
        lines.append("Voice calibration: \(sentences.count) \(sentences.count == 1 ? "sentence" : "sentences")")
        lines.append("")

        if !analysis.scores.isEmpty {
            let rows = [["Engine", "Words right", "Glossary terms right", "Speed"]]
                + analysis.scores.map { [$0.engine.shortName, accuracy($0), terms($0), speed($0)] }
            let widths = (0..<4).map { column in rows.map { $0[column].count }.max() ?? 0 }
            for row in rows {
                var line = ""
                for (column, cell) in row.enumerated() {
                    line += column == row.count - 1 ? cell : cell.padding(toLength: widths[column] + 2, withPad: " ", startingAt: 0)
                }
                lines.append(line)
            }
            lines.append("")
        }
        for failure in analysis.failures {
            lines.append("\(failure.engine.shortName) couldn't be measured: \(failure.message)")
        }
        if !analysis.failures.isEmpty { lines.append("") }

        lines.append(analysis.recommendation.summary(scores: analysis.scores, notCompared: notCompared))
        lines.append("")

        lines.append("Learned corrections ([x] = would be ticked):")
        if corrections.isEmpty {
            lines.append("  None: no glossary term came out as something else.")
        }
        for correction in corrections {
            var line = "  [\(correction.isSuggested ? "x" : " ")] heard \"\(correction.heard)\" → \(correction.term)"
            line += "   (\(engineList(correction.engines))\(correction.count > 1 ? ", \(correction.count) times" : ""))"
            if correction.isOrdinaryPhrase {
                line += "   ordinary words: replacing them everywhere would change normal sentences"
            }
            lines.append(line)
        }
        lines.append("")

        lines.append("Style notes on offer (for Claude, never replaced blindly):")
        if styleNotes.isEmpty { lines.append("  None.") }
        for note in styleNotes {
            lines.append("  [ ] \(note.text)   (\(engineList(note.engines))\(note.count > 1 ? ", \(note.count) times" : ""))")
        }

        if details {
            lines.append("")
            lines.append("Sentence by sentence:")
            for sentence in sentences {
                lines.append("  \(sentence.id)  \(sentence.text)")
                for score in analysis.scores {
                    guard let result = score.sentences.first(where: { $0.sentenceID == sentence.id }) else { continue }
                    let name = score.engine.shortName.padding(toLength: 9, withPad: " ", startingAt: 0)
                    let errors = result.wordErrors == 0 ? "all right" : "\(result.wordErrors) of \(result.referenceWords) words wrong"
                    lines.append("       \(name) \(result.transcript)   [\(errors)]")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
