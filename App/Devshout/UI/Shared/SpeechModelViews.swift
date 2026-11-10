// Speech model pickers and status, shared by onboarding and Settings → Transcription.
//
// Unsure on macOS (not compiled here): nothing beyond standard SwiftUI controls.

import DevshoutCore
import SwiftUI

/// A selectable card for one engine.
struct EngineCard: View {
    let info: SpeechEngineInfo
    let status: SpeechModelStatus
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    Text(info.id.displayName).font(.headline)
                    Spacer(minLength: 0)
                    if info.isRecommended {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(Color.accentColor)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                Text(info.summary).font(.callout)
                Text(info.detail).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(status.isReady ? status.summary : "About \(UIFormat.bytes(info.approximateDownloadBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(12)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Progress bar and summary for a model that is downloading or loading; status line otherwise.
struct ModelProgressView: View {
    let status: SpeechModelStatus

    var body: some View {
        switch status {
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = status.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(status.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(status.summary).foregroundStyle(.secondary)
            }
        case .ready:
            StatusLabel(text: status.summary, tone: .positive)
        case .notDownloaded:
            StatusLabel(text: status.summary, tone: .neutral, symbolName: "arrow.down.circle")
        case .failed:
            StatusLabel(text: status.summary, tone: .critical)
        }
    }
}

/// Download / Cancel / Delete buttons for one engine's model.
struct ModelActionButtons: View {
    @ObservedObject var model: SpeechEngineViewModel
    let engine: EngineID
    @State private var confirmingDelete = false

    var body: some View {
        let status = model.status(for: engine)
        HStack(spacing: 8) {
            switch status {
            case .notDownloaded:
                Button("Download") { model.download(engine) }
            case .failed:
                Button("Try Again") { model.download(engine) }
            case .downloading:
                Button("Cancel") { model.cancelDownload(engine) }
            case .preparing:
                EmptyView()
            case .ready:
                Button("Delete…") { confirmingDelete = true }
            }
        }
        .confirmationDialog("Delete the \(engine.displayName) model?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.delete(engine) }
        } message: {
            Text("You can download it again at any time.")
        }
    }
}

#Preview("Engine cards") {
    HStack {
        EngineCard(info: .info(for: .parakeetV3), status: PreviewData.downloading, isSelected: true, select: {})
        EngineCard(info: .info(for: .whisperLargeV3Turbo), status: .notDownloaded, isSelected: false, select: {})
    }
    .padding()
    .frame(width: 560)
}

#Preview("Progress") {
    VStack(alignment: .leading, spacing: 16) {
        ModelProgressView(status: PreviewData.downloading)
        ModelProgressView(status: .preparing(.compiling))
        ModelProgressView(status: .ready(sizeOnDisk: 486_000_000))
        ModelProgressView(status: .failed(message: "The network connection was lost."))
    }
    .padding()
    .frame(width: 360)
}
