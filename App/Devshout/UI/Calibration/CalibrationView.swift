// The "Calibrate your voice" window's content, hosted by `CalibrationWindowController`: introduction, the script a
// sentence at a time, the analysis progress and the results. Dumb views over `CalibrationViewModel`; the wording is in
// `CalibrationCopy`. Nothing here holds the microphone: the controller starts and stops it from the buttons and
// from the window closing.

import DevshoutCore
import SwiftUI

struct CalibrationView: View {
    @ObservedObject var model: CalibrationViewModel

    /// The window's content size (fixed).
    static let size = CGSize(width: 640, height: 560)

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .intro: CalibrationIntroView(model: model)
        case .preparing: CalibrationPreparingView()
        case .reading: CalibrationReadingView(model: model)
        case .analysing: CalibrationAnalysingView(model: model)
        case .results: CalibrationResultsView(model: model)
        case .failed(let message): CalibrationFailedView(message: message)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch model.stage {
            case .intro:
                Button(CalibrationCopy.closeButton) { model.close() }
                Spacer()
                Button(CalibrationCopy.beginButton) { model.begin() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canBegin)
            case .preparing:
                Spacer()
                Button(CalibrationCopy.useBuiltInButton) { model.useBuiltInSentences() }
            case .reading:
                Button(CalibrationCopy.backButton) { model.back() }
                    .disabled(!model.canGoBack)
                Spacer()
                CalibrationReadingButtons(model: model)
            case .analysing:
                Spacer()
                Button(CalibrationCopy.cancelButton) { model.cancelAnalysis() }
            case .results:
                Spacer()
                Button(CalibrationCopy.doneButton) { model.close() }
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Button(CalibrationCopy.closeButton) { model.close() }
                Spacer()
                Button(CalibrationCopy.tryAgainButton) { model.begin() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canBegin)
            }
        }
        .controlSize(.large)
    }
}

// MARK: - Introduction

private struct CalibrationIntroView: View {
    @ObservedObject var model: CalibrationViewModel

    var body: some View {
        VStack(spacing: 14) {
            SymbolTile(systemName: "person.wave.2", tint: .teal)
            Text(CalibrationCopy.introTitle)
                .font(.title.weight(.semibold))
            Text(CalibrationCopy.introMessage)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(CalibrationCopy.introSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)
                        Text(step)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))

            VStack(alignment: .leading, spacing: 6) {
                let engines = CalibrationCopy.introEngines(ready: model.readyEngines, missing: model.missingEngines)
                StatusLabel(text: engines.text, tone: engines.tone)
                    .fixedSize(horizontal: false, vertical: true)
                if model.microphoneDenied {
                    HStack {
                        StatusLabel(text: CalibrationCopy.microphoneDenied, tone: .critical)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Open System Settings") { model.microphone.openPrivacySettings() }
                    }
                }
                StatusLabel(text: CalibrationCopy.introPrivacy, tone: .neutral, symbolName: "lock")
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 20)
    }
}

// MARK: - Writing the script

private struct CalibrationPreparingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(CalibrationCopy.preparingTitle)
                .font(.title3.weight(.semibold))
            Text(CalibrationCopy.preparingDetail)
                .foregroundStyle(.secondary)
        }
        .padding(48)
    }
}

// MARK: - Reading

private struct CalibrationReadingView: View {
    @ObservedObject var model: CalibrationViewModel

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text(CalibrationCopy.sentenceCounter(index: model.index, count: model.sentences.count))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(model.recordedCount), total: Double(max(model.sentences.count, 1)))
                    .frame(width: 220)
            }

            Text(model.currentSentence?.text ?? "")
                .font(.system(size: 26, weight: .medium))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 170, alignment: .center)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: model.isRecording ? "record.circle.fill" : "mic")
                        .foregroundStyle(model.isRecording ? Color.red : Color.secondary)
                    LevelMeter(level: model.level)
                        .frame(width: 240)
                    CalibrationTimer(since: model.recordingSince)
                        .frame(width: 52, alignment: .leading)
                }
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let notice = model.notice {
                    StatusLabel(text: notice, tone: .warning)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
    }

    private var hint: String {
        switch model.recording {
        case .starting: return CalibrationCopy.startingHint
        case .recording: return CalibrationCopy.recordingHint
        case .stopping: return CalibrationCopy.stoppingHint
        case .idle:
            if let duration = model.currentTakeDuration { return CalibrationCopy.recordedHint(duration) }
            return CalibrationCopy.readingHint
        }
    }
}

/// "00:07" while recording; blank otherwise.
private struct CalibrationTimer: View {
    let since: Date?

    var body: some View {
        if let since {
            TimelineView(.periodic(from: since, by: 0.5)) { context in
                Text(UIFormat.timer(context.date.timeIntervalSince(since)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(" ").font(.callout.monospacedDigit())
        }
    }
}

/// Record, Stop, or Record Again and Next: Return always presses the one that moves things on.
private struct CalibrationReadingButtons: View {
    @ObservedObject var model: CalibrationViewModel

    var body: some View {
        switch model.recording {
        case .starting, .stopping:
            Button(CalibrationCopy.stopButton) {}
                .disabled(true)
        case .recording:
            Button {
                model.stop()
            } label: {
                Label(CalibrationCopy.stopButton, systemImage: "stop.fill")
            }
            .keyboardShortcut(.defaultAction)
        case .idle:
            if model.hasTake {
                Button(CalibrationCopy.recordAgainButton) { model.record() }
                Button(model.isLastSentence ? CalibrationCopy.finishButton : CalibrationCopy.nextButton) { model.next() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    model.record()
                } label: {
                    Label(CalibrationCopy.recordButton, systemImage: "mic.fill")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Analysing

private struct CalibrationAnalysingView: View {
    @ObservedObject var model: CalibrationViewModel

    var body: some View {
        VStack(spacing: 16) {
            SymbolTile(systemName: "waveform.badge.magnifyingglass", tint: .indigo)
            Text(CalibrationCopy.analysingTitle)
                .font(.title2.weight(.semibold))
            ProgressView(value: min(max(model.progress.fraction, 0), 1))
                .frame(width: 320)
            Text(CalibrationCopy.analysing(model.progress))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(48)
    }
}

// MARK: - Results

private struct CalibrationResultsView: View {
    @ObservedObject var model: CalibrationViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let results = model.results {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(CalibrationCopy.resultsTitle)
                            .font(.title2.weight(.semibold))
                        Text(results.summary)
                            .font(.title3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let engine = model.engineToSwitchTo {
                            Button(CalibrationCopy.switchButton(engine)) { model.switchEngine() }
                                .buttonStyle(.borderedProminent)
                        } else if let engine = results.recommendation.engine, engine == model.speech.selectedEngine,
                                  results.scores.count > 1 {
                            StatusLabel(text: CalibrationCopy.nowUsing(engine), tone: .positive)
                                .font(.callout)
                        }
                    }

                    CalibrationScoreTable(results: results, selected: model.speech.selectedEngine)

                    ForEach(results.failures, id: \.engine) { failure in
                        StatusLabel(text: CalibrationCopy.failure(failure), tone: .warning)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                CalibrationLearningView(model: model)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One row per engine: words right, glossary terms right, speed.
private struct CalibrationScoreTable: View {
    let results: CalibrationResults
    let selected: EngineID

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 10) {
            GridRow {
                Text(CalibrationCopy.columnEngine)
                Text(CalibrationCopy.columnAccuracy)
                Text(CalibrationCopy.columnTerms)
                Text(CalibrationCopy.columnSpeed)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(results.scores, id: \.engine) { score in
                GridRow {
                    HStack(spacing: 6) {
                        Text(score.engine.shortName)
                            .fontWeight(score.engine == results.recommendation.engine ? .semibold : .regular)
                        if score.engine == selected {
                            Text(CalibrationCopy.inUse)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .foregroundStyle(Color.accentColor)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                    }
                    Text(CalibrationCopy.accuracy(score))
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text(CalibrationCopy.terms(score))
                        .monospacedDigit()
                    Text(CalibrationCopy.speed(score))
                        .monospacedDigit()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// The mishearings and notes, with tick boxes, and "Add to Glossary".
private struct CalibrationLearningView: View {
    @ObservedObject var model: CalibrationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(CalibrationCopy.correctionsTitle)
                .font(.headline)
            if model.corrections.isEmpty {
                Text(CalibrationCopy.noCorrections)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(CalibrationCopy.correctionsExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.corrections) { row in
                    CalibrationCorrectionRowView(row: row, isOn: model.correctionBinding(row.id))
                }
            }

            if !model.notes.isEmpty {
                Text(CalibrationCopy.notesTitle)
                    .font(.headline)
                    .padding(.top, 8)
                Text(CalibrationCopy.notesExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.notes) { row in
                    Toggle(isOn: model.noteBinding(row.id)) {
                        HStack(spacing: 8) {
                            Text(CalibrationCopy.note(row.note))
                            if row.isApplied { AddedBadge() }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(row.isApplied)
                }
            }

            if model.hasLearningToOffer {
                HStack(spacing: 12) {
                    Button(CalibrationCopy.applyButton) { model.applyLearning() }
                        .disabled(model.selectedLearningCount == 0)
                    if let message = model.learningMessage {
                        StatusLabel(text: message, tone: model.learningFailed ? .critical : .positive)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}

private struct CalibrationCorrectionRowView: View {
    let row: CalibrationCorrectionRow
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $isOn) {
                HStack(spacing: 6) {
                    Text(CalibrationCopy.correctionHeard(row.correction)).italic()
                    Image(systemName: "arrow.right").imageScale(.small).foregroundStyle(.secondary)
                    Text(row.correction.term).fontWeight(.semibold)
                    Text(CalibrationCopy.correctionDetail(row.correction))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if row.isApplied { AddedBadge() }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(row.isApplied)
            if row.correction.isOrdinaryPhrase, !row.isApplied {
                Label(CalibrationCopy.ordinaryWarning(row.correction), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
    }
}

private struct AddedBadge: View {
    var body: some View {
        Label(CalibrationCopy.added, systemImage: "checkmark")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
    }
}

// MARK: - Failed

private struct CalibrationFailedView: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            SymbolTile(systemName: "exclamationmark.triangle", tint: .orange)
            Text(CalibrationCopy.failedTitle)
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(48)
    }
}

// MARK: - Previews

#Preview("Intro") {
    CalibrationView(model: PreviewData.calibration(.intro))
}

#Preview("Intro: one model") {
    CalibrationView(model: PreviewData.calibration(.intro, bothEngines: false))
}

#Preview("Intro: no model") {
    CalibrationView(model: PreviewData.calibration(.intro, speechStatus: .notDownloaded, bothEngines: false))
}

#Preview("Writing the script") {
    CalibrationView(model: PreviewData.calibration(.preparing))
}

#Preview("Reading: ready to record") {
    CalibrationView(model: PreviewData.calibration(.reading))
}

#Preview("Reading: recording") {
    CalibrationView(model: PreviewData.calibration(.reading, recording: .recording(since: Date().addingTimeInterval(-4))))
}

#Preview("Reading: recorded") {
    CalibrationView(model: PreviewData.calibration(.reading, recorded: 6))
}

#Preview("Reading: last sentence, with a notice") {
    let model = PreviewData.calibration(.reading, recorded: 9)
    model.notice = CalibrationCopy.takeTooShort
    return CalibrationView(model: model)
}

#Preview("Analysing") {
    CalibrationView(model: PreviewData.calibration(.analysing))
}

#Preview("Results: two models") {
    CalibrationView(model: PreviewData.calibration(.results))
}

#Preview("Results: one model") {
    CalibrationView(model: PreviewData.calibration(.results, bothEngines: false))
}

#Preview("Results: added to the glossary") {
    let model = PreviewData.calibration(.results)
    model.corrections[0].isApplied = true
    model.learningMessage = CalibrationCopy.applied(corrections: 1, notes: 0)
    return CalibrationView(model: model)
}

#Preview("Failed") {
    CalibrationView(model: PreviewData.calibration(.failed(message: CalibrationCopy.noEngineReady)))
}
