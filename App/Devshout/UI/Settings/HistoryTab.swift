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

#Preview("History") {
    HistorySettingsTab(model: HistoryViewModel(recordings: PreviewData.recordings))
}

#Preview("History: searching") {
    HistorySettingsTab(model: HistoryViewModel(recordings: PreviewData.recordings, searchText: "corsia"))
}

#Preview("History: nothing matches") {
    HistorySettingsTab(model: HistoryViewModel(recordings: PreviewData.recordings, searchText: "procurement"))
}

#Preview("History: empty") {
    HistorySettingsTab(model: HistoryViewModel())
}
