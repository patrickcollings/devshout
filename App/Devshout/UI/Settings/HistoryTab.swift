// Settings → History: every dictation, newest first, with what was pasted and what the engine heard.

import DevshoutCore
import SwiftUI

struct HistorySettingsTab: View {
    @ObservedObject var model: HistoryViewModel
    @State private var confirmingDelete = false

    var body: some View {
        let visible = model.visibleRecordings
        let selected = model.selectedRecording
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
                    VStack(spacing: 0) {
                        HistorySearchField(text: $model.searchText)
                            .padding(8)
                        Divider()
                        if visible.isEmpty {
                            Text(HistoryText.noMatches(for: model.searchText))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(12)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List(visible, selection: $model.selection) { recording in
                                HistoryRow(recording: recording).tag(recording.id)
                            }
                        }
                    }
                    .frame(width: 230)
                    Divider()
                    if let selected {
                        HistoryDetail(recording: selected, model: model, confirmingDelete: $confirmingDelete)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(width: SettingsLayout.width, height: 470)
        .onAppear { model.reload() }
        .confirmationDialog("Delete this dictation?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if let selected { model.delete(selected.id) }
                model.selection = nil
            }
        } message: {
            Text("This deletes its audio and its text. It can't be undone.")
        }
    }
}

/// The search field above the list: a magnifying glass, the text, and a button to clear it.
private struct HistorySearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search dictations", text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
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
        let sections = HistoryText.sections(for: recording)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ModeChip(mode: recording.mode, compact: true)
                Text(HistoryText.facts(for: recording))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HistoryActionBar(recording: recording, model: model)

            if let problem = recording.errorMessage ?? recording.fallbackReason {
                StatusLabel(text: problem, tone: recording.status == .failed ? .critical : .warning)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = model.playbackProblem(for: recording.id) {
                StatusLabel(text: problem, tone: .warning)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HistoryRerunStatus(recording: recording, model: model)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if sections.isEmpty {
                        Text("No text was transcribed.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sections) { section in
                        HistoryTextBlock(section: section)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Copy") {
                    if let first = sections.first { UIClipboard.copy(first.text) }
                }
                .disabled(sections.isEmpty)
                .help(sections.count > 1 ? "Copy the first text shown" : "Copy the text")
                Button("Show in Finder") { model.showInFinder(recording.id) }
                Spacer()
                Button("Delete…", role: .destructive) { confirmingDelete = true }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The compact row of things to do with the recording, under its facts.
private struct HistoryActionBar: View {
    let recording: Recording
    @ObservedObject var model: HistoryViewModel

    var body: some View {
        HStack(spacing: 8) {
            playButton
            rerunMenu
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var rerunMenu: some View {
        Menu {
            ForEach(HistoryViewModel.rerunModes, id: \.self) { mode in
                Button {
                    model.rerun(recording.id, mode: mode)
                } label: {
                    Label(mode.displayName, systemImage: mode.symbolName)
                }
            }
        } label: {
            Label("Re-run", systemImage: "arrow.clockwise")
        }
        .fixedSize()
        .disabled(!model.canRerun(recording))
        .help(HistoryText.rerunHelp)
    }

    @ViewBuilder
    private var playButton: some View {
        if recording.audioDeletedAt != nil {
            // Retention removed the audio; the text is all that is left.
            Button {} label: {
                Label(HistoryText.audioDeletedLabel, systemImage: "speaker.slash")
            }
            .disabled(true)
            .help(HistoryText.audioDeletedHelp(for: recording))
        } else if model.isPlaying(recording.id) {
            Button {
                model.togglePlayback(recording.id)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .help("Stop playing")
        } else {
            Button {
                model.togglePlayback(recording.id)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .help("Play the recording")
        }
    }
}

/// A re-run through Claude: a spinner with Cancel while it runs, or why the last one failed.
private struct HistoryRerunStatus: View {
    let recording: Recording
    @ObservedObject var model: HistoryViewModel

    var body: some View {
        switch model.reruns[recording.id] {
        case .running(let mode, let claudeModel):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(HistoryText.rerunProgress(mode: mode, model: claudeModel))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Cancel") { model.cancelRerun(recording.id) }
                    .controlSize(.small)
            }
        case .failed(_, let message):
            StatusLabel(text: message, tone: .warning)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }
}

/// One titled text, with its own copy button.
private struct HistoryTextBlock: View {
    let section: HistorySection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(section.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    UIClipboard.copy(section.text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copy this text")
                .accessibilityLabel("Copy this text")
            }
            Text(section.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let note = section.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview("History") {
    HistorySettingsTab(model: HistoryViewModel(recordings: PreviewData.recordings))
}

#Preview("History: searching") {
    HistorySettingsTab(model: HistoryViewModel(recordings: PreviewData.recordings, searchText: "corsia"))
}

#Preview("History: nothing matches") {
    HistorySettingsTab(model: HistoryViewModel(recordings: PreviewData.recordings, searchText: "biodiversity"))
}

#Preview("History: playing") {
    let model = HistoryViewModel(recordings: PreviewData.recordings)
    model.playbackStarted(PreviewData.recordings[0].id)
    return HistorySettingsTab(model: model)
}

#Preview("History: audio deleted") {
    HistorySettingsTab(model: HistoryViewModel(recordings: PreviewData.recordings,
                                               selection: PreviewData.recordings[3].id))
}

#Preview("History: several versions") {
    HistorySettingsTab(model: HistoryViewModel(recordings: PreviewData.recordings,
                                               selection: PreviewData.recordings[1].id))
}

#Preview("History: re-running") {
    let model = HistoryViewModel(recordings: PreviewData.recordings)
    model.rerunStarted(PreviewData.recordings[0].id, mode: .structure, model: "sonnet")
    return HistorySettingsTab(model: model)
}

#Preview("History: re-run failed") {
    let model = HistoryViewModel(recordings: PreviewData.recordings)
    model.rerunFailed(PreviewData.recordings[0].id, mode: .structure,
                      message: HistoryText.rerunFailed(mode: .structure, .timedOut(after: 45)))
    return HistorySettingsTab(model: model)
}

#Preview("History: audio file missing") {
    let model = HistoryViewModel(recordings: PreviewData.recordings)
    model.playbackUnavailable(PreviewData.recordings[0].id, message: HistoryText.audioMissing)
    return HistorySettingsTab(model: model)
}

#Preview("History: empty") {
    HistorySettingsTab(model: HistoryViewModel())
}
