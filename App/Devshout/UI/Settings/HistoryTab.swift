// Settings → History: every dictation, newest first, with what was pasted and what the engine heard.

import DevshoutCore
import SwiftUI

struct HistorySettingsTab: View {
    @ObservedObject var model: HistoryViewModel
    @State private var selection: UUID?
    @State private var confirmingDelete = false

    private var selected: Recording? {
        model.recordings.first { $0.id == selection } ?? model.recordings.first
    }

    var body: some View {
        Group {
            if model.recordings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No dictations yet").font(.headline)
                    Text("Each dictation is kept here with its text, so nothing you say is lost.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(model.recordings, selection: $selection) { recording in
                        HistoryRow(recording: recording).tag(recording.id)
                    }
                    .frame(width: 230)
                    Divider()
                    if let selected {
                        HistoryDetail(recording: selected, model: model, confirmingDelete: $confirmingDelete)
                    }
                }
            }
        }
        .frame(width: SettingsLayout.width, height: 470)
        .onAppear { model.reload() }
        .confirmationDialog("Delete this dictation?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if let selected { model.delete(selected.id) }
                selection = nil
            }
        } message: {
            Text("This deletes its audio and its text. It can't be undone.")
        }
    }
}

private struct HistoryRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(UIFormat.day(recording.createdAt)), \(UIFormat.time(recording.createdAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if recording.status != .completed {
                    Text(recording.status.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(recording.status == .failed ? Color.red : Color.orange)
                }
            }
            Text(HistoryText.snippet(for: recording))
                .font(.callout)
                .lineLimit(2)
                .foregroundStyle(HistoryText.bestText(for: recording) == nil ? .secondary : .primary)
        }
        .padding(.vertical, 2)
    }
}

private struct HistoryDetail: View {
    let recording: Recording
    @ObservedObject var model: HistoryViewModel
    @Binding var confirmingDelete: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ModeChip(mode: recording.mode, compact: true)
                Text(HistoryText.facts(for: recording))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if let problem = recording.errorMessage ?? recording.fallbackReason {
                StatusLabel(text: problem, tone: recording.status == .failed ? .critical : .warning)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let text = HistoryText.bestText(for: recording) {
                        HistoryTextBlock(title: HistoryText.bestTitle(for: recording), text: text)
                    } else {
                        Text("No text was transcribed.")
                            .foregroundStyle(.secondary)
                    }
                    if let heard = HistoryText.heardText(for: recording) {
                        HistoryTextBlock(title: "As heard, before Claude", text: heard)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Copy") {
                    if let text = HistoryText.bestText(for: recording) { UIClipboard.copy(text) }
                }
                .disabled(HistoryText.bestText(for: recording) == nil)
                Button("Show in Finder") { model.showInFinder(recording.id) }
                Spacer()
                Button("Delete…", role: .destructive) { confirmingDelete = true }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct HistoryTextBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the History tab says about a recording.
enum HistoryText {
    /// The text to show first and to copy: what was pasted, else the cleaned text, else the transcript.
    static func bestText(for recording: Recording) -> String? {
        for candidate in [recording.deliveredText, recording.latestVersion?.text, recording.transcript] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return nil
    }

    static func bestTitle(for recording: Recording) -> String {
        guard recording.deliveredText != nil, let delivered = recording.delivered else { return "Transcript (not pasted)" }
        switch delivered.method {
        case .pasted: return delivered.appName.map { "Pasted into \($0)" } ?? "Pasted"
        case .copiedOnly: return "Copied to the clipboard"
        case .failed: return "Not pasted"
        }
    }

    /// The transcript before clean-up, when it differs from the text shown first.
    static func heardText(for recording: Recording) -> String? {
        guard let heard = recording.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !heard.isEmpty,
              heard != bestText(for: recording) else { return nil }
        return heard
    }

    static func snippet(for recording: Recording) -> String {
        bestText(for: recording) ?? recording.errorMessage ?? "No text"
    }

    /// "00:07 · Whisper large-v3-turbo · took 3.2 s"
    static func facts(for recording: Recording) -> String {
        var parts = [UIFormat.timer(recording.duration)]
        if let engine = recording.engine { parts.append(engine.displayName) }
        if let total = recording.timings.total { parts.append("took \(UIFormat.seconds(total))") }
        return parts.joined(separator: " · ")
    }
}

#Preview("History") {
    HistorySettingsTab(model: HistoryViewModel(recordings: [
        Recording(id: UUID(), createdAt: Date(), duration: 7, mode: .tidy, engine: .parakeetV3,
                  rawText: "um can you check the corsia flag", deliveredText: "Can you check the CORSIA flag?",
                  delivered: DeliveryRecord(.pasted(appName: "Slack"))),
        Recording(id: UUID(), createdAt: Date().addingTimeInterval(-3600), duration: 3, status: .failed,
                  errorMessage: "No speech was detected."),
    ]))
}

#Preview("History: empty") {
    HistorySettingsTab(model: HistoryViewModel())
}
