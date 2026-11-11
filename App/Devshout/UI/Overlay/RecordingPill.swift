// The recording overlay capsule (PLAN §7.3): about 300×44, HUD material, mode chip, live waveform, timer, Stop and
// Cancel on hover, and the recording / transcribing / cleaning / done / fallback / error states. An optional second
// line shows the latest live transcript. Hosted by `OverlayPanel`.
//
// Unsure on macOS (not compiled here):
// - `.symbolEffect(.pulse, options: .repeating)` (macOS 14) on the recording dot and the cleaning sparkles.
// - SwiftUI `.onHover` in a panel that never becomes key; `OverlayPanel` also reports hover through
//   `RecordingPillViewModel.isHovering` from an AppKit tracking area, and the pill uses either.
// - "Paste raw now" has no ⏎ shortcut here: the panel never becomes key, so wiring registers ⌥Return globally
//   while the cleaning state is showing (DictationController).

import DevshoutCore
import SwiftUI

struct RecordingPill: View {
    @ObservedObject var model: RecordingPillViewModel
    @State private var isHoveringLocally = false

    static let width: CGFloat = 300
    static let lineHeight: CGFloat = 44
    static let chipNameWidthRecording: CGFloat = 80
    static let chipNameWidth: CGFloat = 54

    private var showsControls: Bool { model.phase.isRecording && (model.isHovering || isHoveringLocally) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PhaseIndicator(phase: model.phase)
                // The built-in names always fit. A longer custom name is cut to what the line has room for: beside
                // the waveform and timer while recording, and to the width of "Structure" once the line carries
                // text ("Rewriting with Sonnet…", "Pasted into Slack").
                ModeChip(mode: model.modeDescriptor, compact: true,
                         nameWidth: model.phase.isRecording ? Self.chipNameWidthRecording : Self.chipNameWidth)
                centre
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .frame(height: Self.lineHeight)

            if let line = model.secondLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.bottom, 10)
                    .padding(.top, -4)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: Self.width)
        .background(PillBackground(tone: model.phase.tone))
        .environment(\.colorScheme, .dark)
        .onHover { isHoveringLocally = $0 }
        .animation(.easeInOut(duration: 0.2), value: model.phase)
        .animation(.easeInOut(duration: 0.15), value: showsControls)
        .animation(.easeInOut(duration: 0.2), value: model.secondLine)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("devshout: \(model.title)")
    }

    @ViewBuilder
    private var centre: some View {
        if model.phase.isRecording {
            WaveformView(level: model.levels, barCount: 26, color: .white.opacity(0.9))
                .frame(height: 22)
        } else {
            Text(model.title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if showsControls {
            HStack(spacing: 6) {
                PillIconButton(systemName: "stop.fill", help: "Stop and paste") { model.stop() }
                PillIconButton(systemName: "xmark", help: "Cancel (Esc)") { model.cancel() }
            }
            .transition(.opacity)
        } else if model.phase.isRecording {
            PillTimer(startedAt: model.startedAt, frozen: model.finalDuration)
        } else if isTranscribing {
            HStack(spacing: 6) {
                PillTimer(startedAt: model.startedAt, frozen: model.finalDuration)
                dismissButton
            }
        } else if model.showsPasteRawButton {
            HStack(spacing: 6) {
                Button("Paste raw now ⌥⏎") { model.pasteRawNow() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Skip Claude and paste what was transcribed")
                dismissButton
            }
        }
    }

    /// After recording has stopped Esc is no longer devshout's, so the pill always offers a way out.
    private var dismissButton: some View {
        PillIconButton(systemName: "xmark", help: "Cancel: nothing is pasted, and the recording stays in history") {
            model.cancel()
        }
    }

    private var isTranscribing: Bool { if case .transcribing = model.phase { true } else { false } }
}

// MARK: - Parts

private struct PhaseIndicator: View {
    let phase: PillPhase

    var body: some View {
        Group {
            switch phase {
            case .recording:
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
            case .cleaning:
                Image(systemName: phase.symbolName)
                    .foregroundStyle(.yellow)
                    .symbolEffect(.pulse, options: .repeating)
            default:
                Image(systemName: phase.symbolName)
                    .foregroundStyle(phase.tone.color)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

private struct PillTimer: View {
    let startedAt: Date
    let frozen: TimeInterval?

    var body: some View {
        Group {
            if let frozen {
                Text(UIFormat.timer(frozen))
            } else {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(UIFormat.timer(context.date.timeIntervalSince(startedAt)))
                }
            }
        }
        .font(.callout.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

private struct PillIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.16)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct PillBackground: View {
    let tone: StatusTone

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: RecordingPill.lineHeight / 2, style: .continuous) }

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow,
                                   cornerRadius: RecordingPill.lineHeight / 2)
            tint
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    private var tint: Color {
        switch tone {
        case .warning: Color.orange.opacity(0.28)
        case .critical: Color.red.opacity(0.3)
        case .positive: Color.green.opacity(0.12)
        case .neutral: Color.clear
        }
    }
}

// MARK: - Previews

#Preview("Pill states") {
    VStack(spacing: 14) {
        RecordingPill(model: PreviewData.pill(.recording, mode: .structure))
        RecordingPill(model: PreviewData.pill(.recording, mode: .tidy,
                                              liveText: "so the idea is that the CORSIA flag on AB-1234 should only show when"))
        RecordingPill(model: PreviewData.pill(.recording, mode: PreviewData.customModes[1].id))
        RecordingPill(model: PreviewData.pill(.recording, mode: PreviewData.customModes[0].id,
                                              liveText: "a long mode name is cut short so the timer and waveform keep their room"))
        RecordingPill(model: PreviewData.pill(.cleaning(model: "sonnet"), mode: PreviewData.customModes[0].id))
        RecordingPill(model: PreviewData.pill(.transcribing(remaining: 4)))
        RecordingPill(model: PreviewData.pill(.cleaning(model: "haiku")))
        RecordingPill(model: PreviewData.pill(.done(.pasted(appName: "Slack"))))
        RecordingPill(model: PreviewData.pill(.fallback(reason: "Claude timed out", outcome: .pasted(appName: "Slack"))))
        RecordingPill(model: PreviewData.pill(.done(.copiedOnly(reason: "No text field had focus"))))
        RecordingPill(model: PreviewData.pill(.error(message: "Saved. Couldn't transcribe")))
    }
    .padding(30)
    .background(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
}
